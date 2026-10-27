// SPDX-License-Identifier: MIT
//! emac.device's own state: the base, the block of internal memory the
//! MAC's DMA engine and the interrupt reach, and the hardware's side of
//! the unit - the two descriptor chains, what is being sent, and what
//! came in.
//!
//! **Which hardware.** The MAC (`mac`) and how it reaches its PHY
//! (`port`) are the chip's: on the ESP32-P4 its own 10/100 MAC on RMII
//! (gmac.zig, rmii.zig), on the JH7110 its gigabit MACs on RGMII
//! (eqos.zig, rgmii.zig). Both engines answer the same calls for their
//! descriptors, so the chains below are the same code on either.
//!
//! **Why a second block of memory.** The base is wherever MakeLibrary put
//! it, which is external memory. The engine reads its descriptors and the
//! frames to send from memory and writes received frames there, so all of
//! them live in one block the init allocates internal - and on the JH7110
//! below 4 GiB, where the engine's 32-bit tail pointers reach -
//! aligned to the data cache's 64-byte line: each descriptor and each
//! buffer is whole lines, written back before the engine reads it and
//! invalidated before the task reads what the engine wrote. The interrupt
//! server and what it collects are past them, in lines the engine never
//! touches.
//!
//! **The chains.** `receive_count` descriptors receive and `send_count`
//! send, each followed by the next and the last by the first, each with a
//! buffer of its own that holds a whole frame. Frames come in in order;
//! the task hands each to the unit and gives its descriptor back at once.
//! Writes go out in order too: `sending` holds the request of each send
//! descriptor still in the engine's hands, from `send_done` on, and a
//! write is answered when its descriptor comes back.

const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const TimerBase = sdk.interface.timer.TimerBase;
const phy = @import("phy.zig");
const ethernet = sdk.devices.network.ethernet;
const unit_file = sdk.devices.network.unit;

/// The chip's MAC, and its side of the line to the PHY.
pub const mac = switch (sdk.hardware.chip) {
    .esp32p4 => @import("gmac.zig"),
    .rv64sbi => @import("eqos.zig"),
    .esp32s3 => @compileError("the ESP32-S3 has no Ethernet MAC"),
    .a64psci => @compileError("emac.device: the AArch64 machines' MAC is not driven yet"),
};
pub const port = switch (sdk.hardware.chip) {
    .esp32p4 => @import("rmii.zig"),
    .rv64sbi => @import("rgmii.zig"),
    .esp32s3 => @compileError("the ESP32-S3 has no Ethernet MAC"),
    .a64psci => @compileError("emac.device: the AArch64 machines' MAC is not driven yet"),
};

pub const DEVICE_NAME = "emac.device";

/// Frames that can wait in the receive chain for the task, and frames in
/// the engine's hands to send. A caller that sends more waits in the
/// unit's queue. A frame that comes while the chain is full is lost, so
/// on the JH7110 it holds what a gigabit link brings while the task is
/// late: a 64 KiB TCP window is 45 frames, 12 us apart, and 16 lost the
/// rest of each one. The ESP32-P4's link is 100 Mbit, and its internal
/// memory small.
pub const receive_count = if (sdk.hardware.chip == .rv64sbi) 128 else 16;
pub const send_count = 8;
/// A buffer: the longest frame, with its checksum and a VLAN tag, in
/// whole cache lines.
pub const buffer_bytes = 1536;
/// The data cache's line, which every descriptor and buffer fills whole.
pub const line_bytes = 64;

/// The block the engine and the interrupt reach: internal memory, never
/// moved once the init has it.
pub const Work = extern struct {
    receive_chain: [receive_count]mac.Descriptor align(line_bytes),
    send_chain: [send_count]mac.Descriptor,
    receive: [receive_count][buffer_bytes]u8,
    send: [send_count][buffer_bytes]u8,
    /// The interrupt server, whose data points back at the base.
    int: exec.Interrupt,
    /// What the engine has raised since the task last looked. The server
    /// adds to it and the task takes it.
    raised: u32,
};

pub const Unit = unit_file.Unit(EmacBase);

/// The device's base. One unit, whose port is the task's work queue.
pub const EmacBase = extern struct {
    dev: exec.Device,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    unit: exec.Unit,
    /// The task every request runs on: the openers' copy calls run only
    /// there.
    task: exec.Task,
    stack: ?*anyopaque = null,
    /// The block the engine and the interrupt reach, and the allocation
    /// it is aligned into.
    work: ?*Work = null,
    work_memory: ?*anyopaque = null,
    /// utility.library, for the tag lists OpenDevice is handed.
    utility: ?*UtilityBase = null,
    /// The board's port - the MAC's lines or which MAC - the PHY's address
    /// on the management bus, what the board's wiring asks of the PHY, and
    /// the MAC's interrupt.
    port: port.Port = .{},
    phy_address: u32 = 0,
    wiring: phy.Wiring = .{},
    irq: u32 = 0,
    /// The task's signal the engine's interrupt raises.
    int_mask: u32 = 0,
    /// For the system time a unit goes online at, the waits while the
    /// hardware starts, and the PHY's link asked every `link_poll_us`.
    timer_port: ?*exec.MsgPort = null,
    timer_io: timer.TimeRequest = .{},
    timer_open: u8 = 0,
    /// A link poll is waiting in timer.device.
    polling: u8 = 0,
    /// Whether the interrupt server is hooked up, whether the engine is
    /// receiving and sending, and whether the PHY's link is up.
    hooked: u8 = 0,
    running: u8 = 0,
    link_up: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// The next receive descriptor to look at, the next send descriptor
    /// to fill, the oldest one still sending, and how many are.
    receive_next: u32 = 0,
    send_next: u32 = 0,
    send_done: u32 = 0,
    send_busy: u32 = 0,
    sending: [send_count]?*net.IOSana2Req = @splat(null),
    /// The task that started this one, and the signal it waits on until
    /// the task takes requests.
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    pad2: [3]u8 = .{ 0, 0, 0 },
    /// The requests' side of the unit.
    net: Unit,
    /// What the device was loaded from, for its expunge to hand back.
    seg_list: ?*anyopaque = null,

    // --- the unit's link --------------------------------------------------

    /// The link's speed as the unit reports it: the MAC's best. A link
    /// that came up slower runs slower all the same.
    pub const bps: u64 = if (mac.gigabit) 1_000_000_000 else 100_000_000;

    /// The checksums the MAC does, if it has the engine for them.
    pub fn offload(_: *EmacBase) u32 {
        return if (@hasDecl(mac, "offload")) mac.offload() else 0;
    }

    pub fn setStation(_: *EmacBase, address: *const ethernet.Address) void {
        mac.setStation(address);
    }

    /// The chains set up afresh and the engine started, or the engine
    /// stopped and every write it still had answered.
    pub fn setRunning(base: *EmacBase, on: bool) void {
        const work = base.work.?;
        if (!on) {
            mac.stop();
            base.running = 0;
            base.sent();
            while (base.send_busy > 0) base.finishSend(false);
            return;
        }
        for (&work.receive_chain, 0..) |*descriptor, slot| {
            mac.prepareReceive(descriptor, &work.receive[slot], &work.receive_chain[(slot + 1) % receive_count]);
        }
        for (&work.send_chain, 0..) |*descriptor, slot| {
            mac.prepareSend(descriptor, &work.send[slot], &work.send_chain[(slot + 1) % send_count]);
        }
        base.writeBack(&work.receive_chain, @sizeOf(@TypeOf(work.receive_chain)));
        base.writeBack(&work.send_chain, @sizeOf(@TypeOf(work.send_chain)));
        base.receive_next = 0;
        base.send_next = 0;
        base.send_done = 0;
        base.send_busy = 0;
        mac.start(&work.receive_chain, &work.send_chain);
        base.running = 1;
    }

    /// Every multicast frame taken while any group is joined: the MAC
    /// matches only a few addresses exactly, and the unit drops the
    /// frames of groups nobody here joined.
    pub fn setFilter(_: *EmacBase, groups: []const unit_file.Group, promiscuous: bool) void {
        var multicast = false;
        for (groups) |group| multicast = multicast or group.users != 0;
        mac.setFilter(promiscuous, multicast);
    }

    /// Every free send descriptor given a write, while there are writes.
    pub fn startWrites(base: *EmacBase) void {
        const work = base.work.?;
        var started = false;
        while (base.running != 0 and base.send_busy < send_count) {
            const req = base.net.nextWrite() orelse break;
            const slot = base.send_next;
            const length = base.net.buildFrame(req, &work.send[slot]);
            if (length == 0) continue;
            base.sending[slot] = req;
            base.send_next = (slot + 1) % send_count;
            base.send_busy += 1;
            base.writeBack(&work.send[slot], length);
            const descriptor = &work.send_chain[slot];
            mac.queueSend(descriptor, &work.send[slot], length, req.req.flags & net.SANA2IOF_CHECKSUM != 0);
            base.writeBack(descriptor, @sizeOf(mac.Descriptor));
            started = true;
        }
        if (started) mac.pollSend(&work.send_chain[base.send_next]);
    }

    /// `micros` waited, on the timer.
    pub fn delay(base: *EmacBase, micros: u64) void {
        base.timer_io.node.command = timer.TR_ADDREQUEST;
        base.timer_io.time = timer.TimeVal.fromMicros(micros);
        _ = base.sys_base.DoIO(&base.timer_io.node);
    }

    pub fn now(base: *EmacBase) timer.TimeVal {
        var time: timer.TimeVal = .{};
        if (base.timer_open != 0) {
            const timer_base: *TimerBase = @ptrCast(@alignCast(base.timer_io.node.device.?));
            timer_base.GetSysTime(&time);
        }
        return time;
    }

    // --- the task's side of the chains ------------------------------------

    /// Every frame the engine has put in the chain, handed to the unit,
    /// and its descriptor given back.
    pub fn received(base: *EmacBase) void {
        const work = base.work.?;
        var last: ?*mac.Descriptor = null;
        while (base.running != 0) {
            const slot = base.receive_next;
            const descriptor = &work.receive_chain[slot];
            base.invalidate(descriptor, @sizeOf(mac.Descriptor));
            const frame = mac.received(descriptor, buffer_bytes) orelse break;
            if (!frame.good) {
                base.net.damaged();
            } else {
                base.invalidate(&work.receive[slot], frame.length);
                base.net.receiveWith(work.receive[slot][0..frame.length], if (frame.checked) net.SANA2IOF_CHECKSUM else 0);
            }
            mac.giveBack(descriptor, &work.receive[slot]);
            base.writeBack(descriptor, @sizeOf(mac.Descriptor));
            base.receive_next = (slot + 1) % receive_count;
            last = descriptor;
        }
        if (last) |descriptor| mac.pollReceive(descriptor);
    }

    /// Every write whose descriptor the engine has given back, answered,
    /// and the writes that waited for a descriptor started.
    pub fn sent(base: *EmacBase) void {
        const work = base.work.?;
        while (base.send_busy > 0) {
            const descriptor = &work.send_chain[base.send_done];
            base.invalidate(descriptor, @sizeOf(mac.Descriptor));
            const finished = mac.sendFinished(descriptor);
            if (finished == null and base.running != 0) break;
            base.finishSend(finished orelse false);
        }
        base.startWrites();
    }

    fn finishSend(base: *EmacBase, done: bool) void {
        const slot = base.send_done;
        const req = base.sending[slot].?;
        base.sending[slot] = null;
        base.send_done = (slot + 1) % send_count;
        base.send_busy -= 1;
        base.net.written(req, done);
    }

    /// What the CPU wrote at `address` out to memory, for the engine:
    /// whole lines, which everything here is made of.
    pub fn writeBack(base: *EmacBase, address: *anyopaque, length: u32) void {
        var bytes = wholeLines(length);
        _ = base.sys_base.CachePreDMA(address, &bytes, sdk.exec.DMAF_ReadFromRAM);
    }

    /// What the cache holds of `address` dropped, so the CPU reads what
    /// the engine wrote.
    fn invalidate(base: *EmacBase, address: *anyopaque, length: u32) void {
        var bytes = wholeLines(length);
        base.sys_base.CachePostDMA(address, &bytes, 0);
    }
};

fn wholeLines(length: u32) u32 {
    return (length + line_bytes - 1) & ~@as(u32, line_bytes - 1);
}

pub fn emacBase(dev: *exec.Device) *EmacBase {
    return @fieldParentPtr("dev", dev);
}

/// The base of the request's unit.
pub fn baseOf(io: *exec.IORequest) *EmacBase {
    return @fieldParentPtr("unit", io.unit.?);
}

pub fn sanaReq(io: *exec.IORequest) *net.IOSana2Req {
    return @alignCast(@fieldParentPtr("req", io));
}

/// The request a message on the unit's port belongs to.
pub fn requestOf(msg: *exec.Message) *exec.IORequest {
    return @fieldParentPtr("message", msg);
}
