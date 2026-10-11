// SPDX-License-Identifier: MIT
//! emac.device's own state: the base, the block of internal memory the
//! MAC's DMA engine and the interrupt reach, and the hardware's side of
//! the unit - the two descriptor chains, what is being sent, and what
//! came in.
//!
//! **Why a second block of memory.** The base is wherever MakeLibrary put
//! it, which is external memory. The engine reads its descriptors and the
//! frames to send from memory and writes received frames there, so all of
//! them live in one block the init allocates internal, aligned to the
//! data cache's 64-byte line: each descriptor and each buffer is whole
//! lines, written back before the engine reads it and invalidated before
//! the task reads what the engine wrote. The interrupt server and what it
//! collects are past them, in lines the engine never touches.
//!
//! **The chains.** `receive_count` descriptors receive and `send_count`
//! send, each chained to the next and the last to the first, each with a
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
const gmac = @import("gmac.zig");
const rmii = @import("rmii.zig");
const ethernet = sdk.devices.network.ethernet;
const unit_file = sdk.devices.network.unit;

pub const DEVICE_NAME = "emac.device";

/// Frames that can wait in the receive chain for the task, and frames in
/// the engine's hands to send. A caller that sends more waits in the
/// unit's queue.
pub const receive_count = 16;
pub const send_count = 8;
/// A buffer: the longest frame, with its checksum and a VLAN tag, in
/// whole cache lines.
pub const buffer_bytes = 1536;
/// The data cache's line, which every descriptor and buffer fills whole.
pub const line_bytes = 64;

/// The block the engine and the interrupt reach: internal memory, never
/// moved once the init has it.
pub const Work = extern struct {
    receive_chain: [receive_count]gmac.Descriptor align(line_bytes),
    send_chain: [send_count]gmac.Descriptor,
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
    /// The board's lines, and the PHY's address on the management bus.
    pins: rmii.Pins = .{},
    phy_address: u32 = 0,
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

    /// The link's speed as the unit reports it: the PHY's best. A link
    /// that came up at 10 Mbit/s runs at 10 all the same.
    pub const bps: u64 = 100_000_000;

    pub fn setStation(_: *EmacBase, address: *const ethernet.Address) void {
        gmac.setStation(address);
    }

    /// The chains set up afresh and the engine started, or the engine
    /// stopped and every write it still had answered.
    pub fn setRunning(base: *EmacBase, on: bool) void {
        const work = base.work.?;
        if (!on) {
            gmac.stop();
            base.running = 0;
            base.sent();
            while (base.send_busy > 0) base.finishSend(false);
            return;
        }
        for (&work.receive_chain, 0..) |*descriptor, slot| {
            descriptor.* = .{
                .status = gmac.own,
                .control = gmac.receive_rch | buffer_bytes,
                .buffer = @intCast(@intFromPtr(&work.receive[slot])),
                .next = @intCast(@intFromPtr(&work.receive_chain[(slot + 1) % receive_count])),
            };
        }
        for (&work.send_chain, 0..) |*descriptor, slot| {
            descriptor.* = .{
                .status = gmac.send_tch,
                .buffer = @intCast(@intFromPtr(&work.send[slot])),
                .next = @intCast(@intFromPtr(&work.send_chain[(slot + 1) % send_count])),
            };
        }
        base.writeBack(&work.receive_chain, @sizeOf(@TypeOf(work.receive_chain)));
        base.writeBack(&work.send_chain, @sizeOf(@TypeOf(work.send_chain)));
        base.receive_next = 0;
        base.send_next = 0;
        base.send_done = 0;
        base.send_busy = 0;
        gmac.start(@intFromPtr(&work.receive_chain), @intFromPtr(&work.send_chain));
        base.running = 1;
    }

    /// Every multicast frame taken while any group is joined: the MAC
    /// matches only a few addresses exactly, and the unit drops the
    /// frames of groups nobody here joined.
    pub fn setFilter(_: *EmacBase, groups: []const unit_file.Group, promiscuous: bool) void {
        var multicast = false;
        for (groups) |group| multicast = multicast or group.users != 0;
        gmac.setFilter(promiscuous, multicast);
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
            descriptor.control = length & gmac.send_length_mask;
            descriptor.status = gmac.own | gmac.send_ic | gmac.send_ls | gmac.send_fs | gmac.send_tch;
            base.writeBack(descriptor, @sizeOf(gmac.Descriptor));
            started = true;
        }
        if (started) gmac.pollSend();
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
        var gave_back = false;
        while (base.running != 0) {
            const slot = base.receive_next;
            const descriptor = &work.receive_chain[slot];
            base.invalidate(descriptor, @sizeOf(gmac.Descriptor));
            const status = descriptor.status;
            if (status & gmac.own != 0) break;
            const length = (status >> gmac.receive_length_shift) & gmac.receive_length_mask;
            const whole = gmac.receive_fs | gmac.receive_ls;
            if (status & gmac.receive_es != 0 or status & whole != whole or
                length < gmac.checksum_bytes or length > buffer_bytes)
            {
                base.net.damaged();
            } else {
                base.invalidate(&work.receive[slot], length);
                base.net.receive(work.receive[slot][0 .. length - gmac.checksum_bytes]);
            }
            descriptor.status = gmac.own;
            base.writeBack(descriptor, @sizeOf(gmac.Descriptor));
            base.receive_next = (slot + 1) % receive_count;
            gave_back = true;
        }
        if (gave_back) gmac.pollReceive();
    }

    /// Every write whose descriptor the engine has given back, answered,
    /// and the writes that waited for a descriptor started.
    pub fn sent(base: *EmacBase) void {
        const work = base.work.?;
        while (base.send_busy > 0) {
            const descriptor = &work.send_chain[base.send_done];
            base.invalidate(descriptor, @sizeOf(gmac.Descriptor));
            const status = descriptor.status;
            if (status & gmac.own != 0 and base.running != 0) break;
            base.finishSend(status & (gmac.own | gmac.send_es) == 0);
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
