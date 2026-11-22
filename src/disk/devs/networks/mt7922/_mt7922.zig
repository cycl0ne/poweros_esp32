// SPDX-License-Identifier: MIT
//! networks/mt7922.device's own state: the base, which the unit's link
//! (sdk/devices/network/unit.zig) is, and the worker's block.
//!
//! **The base** holds what the device's calls need: the card's PCI
//! function and registers, its interrupt, the worker and its ports, the
//! unit. **The worker's block** (`Work`) holds what only the worker
//! touches: the rings, the firmware's messages, the radio. It is
//! allocated by the init with the memory the chip reads and writes,
//! which is below 4 GiB (MEMF_DMA).
//!
//! **The interrupt** does no work: it turns the chip's interrupts off and
//! signals the worker, which reads the causes, does what they say and
//! turns them back on.

const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const ethernet = net.ethernet;
const timer = sdk.devices.timer;
const pci = sdk.pci;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const PCIBase = sdk.interface.pci.PCIBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const TimerBase = sdk.interface.timer.TimerBase;
const unit_file = net.unit;
const regs_file = @import("regs.zig");
const dma = @import("dma.zig");
const Regs = regs_file.Regs;
const Ring = dma.Ring;

pub const DEVICE_NAME = "mt7922.device";

/// MediaTek's PCI vendor ID and the cards this device drives.
pub const VENDOR_MEDIATEK: u16 = 0x14C3;
pub const DEVICE_MT7922: u16 = 0x0616;
/// What the chip says it is, once it is up.
pub const CHIP_MT7922: u32 = 0x7922;

pub const Unit = unit_file.Unit(Mt7922Base);

/// How the card raises its interrupt.
pub const Signalling = enum(u8) { none, vector, message, line };

/// A command to the worker.
pub const Command = extern struct {
    message: exec.Message = .{},
    kind: Kind = .quit,

    pub const Kind = enum(u32) { quit };
};

pub const Mt7922Base = extern struct {
    dev: exec.Device,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// What the device was loaded from, for its expunge to hand back.
    seg_list: ?*anyopaque = null,
    pci_base: ?*PCIBase = null,
    dos_base: ?*DosBase = null,
    /// utility.library, for the tag lists OpenDevice and the wireless
    /// requests are handed.
    utility: ?*UtilityBase = null,
    /// The card: its function, claimed, and its registers.
    function: ?*pci.PCIDevice = null,
    regs: usize = 0,
    signalling: Signalling = .none,
    ready: u8 = 0,
    coherent: u8 = 0,
    pad: [1]u8 = .{0},
    /// The interrupt's server, and the signal it gives the worker.
    int: exec.Interrupt = .{},
    int_mask: u32 = 0,
    /// The worker - a DOS process, since the firmware is read from files -
    /// and its block.
    worker: ?*exec.Task = null,
    work: ?*Work = null,
    /// The worker's commands and the unit's requests, on one signal.
    commands: exec.MsgPort = .{},
    work_mask: u32 = 0,
    /// The task that started the worker, and the signal it waits on
    /// until the worker is ready or has given up.
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    pad2: [3]u8 = .{ 0, 0, 0 },
    quit: Command = .{},
    /// What dos replies once the worker is gone.
    ended: exec.Message = .{},
    /// The memory the chip reads and writes: the rings and their buffers.
    dma_memory: ?*anyopaque = null,
    dma_bytes: usize = 0,
    /// The exec unit the openers' requests name; its port is the worker's
    /// queue of them.
    unit: exec.Unit = .{},
    /// The requests' side.
    net: Unit,

    pub fn chipRegs(base: *const Mt7922Base) Regs {
        return .{ .base = base.regs };
    }

    // --- the unit's link ------------------------------------------------------

    /// Two streams at 80 MHz, as far as the unit is told until a network
    /// says otherwise.
    pub const bps: u64 = 1_200_000_000;

    /// The firmware answers to the address it was told when the station
    /// was set up.
    pub fn setStation(base: *Mt7922Base, address: *const ethernet.Address) void {
        _ = base;
        _ = address;
    }

    /// The firmware takes the groups its network sends; the unit sorts out
    /// the ones it joined.
    pub fn setFilter(base: *Mt7922Base, groups: []const unit_file.Group, promiscuous: bool) void {
        _ = base;
        _ = groups;
        _ = promiscuous;
    }

    pub fn setRunning(base: *Mt7922Base, on: bool) void {
        _ = base;
        _ = on;
    }

    /// Nothing is sent until the station is on a network.
    pub fn startWrites(base: *Mt7922Base) void {
        _ = base;
    }

    pub fn now(base: *Mt7922Base) timer.TimeVal {
        var time: timer.TimeVal = .{};
        const work = base.work orelse return time;
        if (work.timer_open) {
            const timer_base: *TimerBase = @ptrCast(@alignCast(work.timer_io.node.device.?));
            timer_base.GetSysTime(&time);
        }
        return time;
    }
};

pub fn mtBase(dev: *exec.Device) *Mt7922Base {
    return @fieldParentPtr("dev", dev);
}

pub fn sanaReq(io: *exec.IORequest) *net.IOSana2Req {
    return @alignCast(@fieldParentPtr("req", io));
}

/// The request a message on a port belongs to.
pub fn requestOf(message: *exec.Message) *exec.IORequest {
    return @fieldParentPtr("message", message);
}

/// A line in the system's log, the device's name in front.
pub fn say(sys: *ExecBase, comptime text: [:0]const u8, args: anytype) void {
    exec.kprintf(sys, "%s: " ++ text ++ "\n", .{@as([*:0]const u8, DEVICE_NAME)} ++ args);
}

// --- the rings ---------------------------------------------------------------

/// How many descriptors each ring has and how large its buffers are. The
/// counts are the host's to choose; these hold what the station has in
/// flight with room to spare.
pub const tx_data_count = 128;
pub const tx_wm_count = 32;
pub const tx_fwdl_count = 64;
pub const rx_wm_count = 8;
pub const rx_wm2_count = 32;
pub const rx_data_count = 128;
pub const tx_buffer = 2048;
pub const wm_buffer = 4096;
pub const rx_buffer = 2048;

/// The rings' numbers in their blocks: data out on 0, the firmware's
/// commands on 17, the firmware itself on 16; events in on 0 before the
/// download and on 4 after it, frames on 2.
pub const ring_tx_data = 0;
pub const ring_tx_fwdl = 16;
pub const ring_tx_wm = 17;
pub const ring_rx_wm = 0;
pub const ring_rx_data = 2;
pub const ring_rx_wm2 = 4;

const ring_align = 256;
const buffer_align = 64;

/// The memory the rings take: their descriptors, each ring aligned, then
/// every buffer.
pub fn dmaBytes() usize {
    const descs = (tx_data_count + tx_wm_count + tx_fwdl_count + rx_wm_count + rx_wm2_count + rx_data_count) * @sizeOf(dma.Desc);
    const buffers = tx_data_count * tx_buffer + tx_wm_count * wm_buffer + (rx_wm_count + rx_wm2_count + rx_data_count) * rx_buffer;
    return descs + 6 * ring_align + buffers + buffer_align;
}

/// The largest answer of the firmware that is kept.
pub const answer_max = 2048;

/// The worker's block: the chip, its rings, what the firmware said.
pub const Work = struct {
    base: *Mt7922Base,
    sys: *ExecBase,
    dl: *DosBase,
    regs: Regs,
    /// For the waits: the worker's own.
    timer_io: timer.TimeRequest = .{},
    timer_port: exec.MsgPort = .{},
    timer_open: bool = false,

    tx_data: Ring = .{},
    tx_wm: Ring = .{},
    tx_fwdl: Ring = .{},
    rx_wm: Ring = .{},
    rx_wm2: Ring = .{},
    rx_data: Ring = .{},

    /// The chip's interrupts the worker wants.
    int_enabled: u32 = 0,
    /// The firmware's messages: the last sequence number used, and the
    /// answer to the one waited for.
    seq: u8 = 0,
    answer: [answer_max]u8 = undefined,
    answer_len: u32 = 0,

    /// What the chip and its firmware said about themselves.
    chip: u32 = 0,
    revision: u32 = 0,
    patch_build: [16:0]u8 = @splat(0),
    ram_build: [16:0]u8 = @splat(0),
    station: ethernet.Address = @splat(0),
    has_5g: bool = false,
    has_6g: bool = false,
    streams: u8 = 0,

    /// The rings laid out in the device's DMA memory.
    pub fn layRings(work: *Work, memory: usize) void {
        var at = memory;
        const rings = [_]struct { ring: *Ring, count: u32, block: u32, number: u32, buffer: u32 }{
            .{ .ring = &work.tx_data, .count = tx_data_count, .block = regs_file.TX_RING_BASE, .number = ring_tx_data, .buffer = tx_buffer },
            .{ .ring = &work.tx_wm, .count = tx_wm_count, .block = regs_file.TX_RING_BASE, .number = ring_tx_wm, .buffer = wm_buffer },
            .{ .ring = &work.tx_fwdl, .count = tx_fwdl_count, .block = regs_file.TX_RING_BASE, .number = ring_tx_fwdl, .buffer = 0 },
            .{ .ring = &work.rx_wm, .count = rx_wm_count, .block = regs_file.RX_RING_BASE, .number = ring_rx_wm, .buffer = rx_buffer },
            .{ .ring = &work.rx_wm2, .count = rx_wm2_count, .block = regs_file.RX_RING_BASE, .number = ring_rx_wm2, .buffer = rx_buffer },
            .{ .ring = &work.rx_data, .count = rx_data_count, .block = regs_file.RX_RING_BASE, .number = ring_rx_data, .buffer = rx_buffer },
        };
        for (rings) |one| {
            at = (at + ring_align - 1) & ~@as(usize, ring_align - 1);
            one.ring.* = .{
                .descs = @ptrFromInt(at),
                .count = one.count,
                .at = Regs.ring(one.block, one.number, 0),
                .buffer_size = one.buffer,
            };
            at += one.count * @sizeOf(dma.Desc);
        }
        at = (at + buffer_align - 1) & ~@as(usize, buffer_align - 1);
        for (rings) |one| {
            if (one.buffer == 0) continue;
            one.ring.buffers = at;
            at += @as(usize, one.count) * one.buffer;
        }
    }

    /// A wait of `us` microseconds.
    pub fn pause(work: *Work, us: u32) void {
        if (!work.timer_open) return;
        work.timer_io.node.command = timer.TR_ADDREQUEST;
        work.timer_io.time = timer.TimeVal.fromMicros(us);
        _ = work.sys.DoIO(&work.timer_io.node);
    }

    /// Whether the bits `mask` of the BAR0 register `offset` came to read
    /// `value` within `ms` milliseconds, looked at every millisecond.
    pub fn poll(work: *Work, offset: u32, mask: u32, value: u32, ms: u32) bool {
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            if (work.regs.rd(offset) & mask == value) return true;
            if (tries >= ms) return false;
            work.pause(1000);
        }
    }

    /// The same for a chip address: the window is moved to it for every
    /// read.
    pub fn pollFar(work: *Work, address: u32, mask: u32, value: u32, ms: u32) bool {
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            if (work.regs.rdFar(address) & mask == value) return true;
            if (tries >= ms) return false;
            work.pause(1000);
        }
    }
};
