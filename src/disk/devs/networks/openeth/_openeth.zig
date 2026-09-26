// SPDX-License-Identifier: MIT
//! openeth.device's own state: the base, the block of internal memory the
//! MAC and the interrupt reach, and the hardware's side of the unit - the
//! rings, what is being sent, and what came in.
//!
//! **Why a second block of memory.** The base is wherever MakeLibrary put
//! it, which is external memory, behind the cache's MMU. The MAC writes a
//! received frame to the bus address in its descriptor and reads a frame
//! to send from there, so every buffer it is given lives in one block the
//! init allocates internal, with the interrupt server beside them.
//!
//! **The rings.** Descriptors 0 to `send_count - 1` send, the next
//! `receive_count` receive, each with a buffer of its own in the block.
//! Frames are received into the ring in order; the task hands each to the
//! unit and gives its descriptor back at once. Writes go out in order
//! too: `sending` holds the request of each send descriptor still in the
//! MAC's hands, from `send_done` on, and a write is answered when its
//! descriptor comes back.

const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const TimerBase = sdk.interface.timer.TimerBase;
const ethmac = @import("ethmac.zig");
const ethernet = sdk.devices.network.ethernet;
const unit_file = sdk.devices.network.unit;

pub const DEVICE_NAME = "openeth.device";

/// Frames that can wait in the receive ring for the task, and frames in
/// the MAC's hands to send. The task empties the receive ring as soon as
/// the interrupt comes, and a caller that sends more waits in the unit's
/// queue; what is deep is the stack's own buffers.
pub const receive_count = 8;
pub const send_count = 4;
/// A buffer: the longest frame the MAC takes, with its checksum.
pub const buffer_bytes = 1536;

/// The block the MAC and the interrupt reach: internal memory, never
/// moved once the init has it.
pub const Work = extern struct {
    /// The interrupt server, whose data points back at the base.
    int: exec.Interrupt = .{},
    /// What the MAC has raised since the task last looked. The server
    /// adds to it and the task takes it.
    raised: u32 = 0,
    receive: [receive_count][buffer_bytes]u8 align(4) = @splat(@splat(0)),
    send: [send_count][buffer_bytes]u8 align(4) = @splat(@splat(0)),
};

pub const Unit = unit_file.Unit(OpenethBase);

/// The device's base. One unit, whose port is the task's work queue.
pub const OpenethBase = extern struct {
    dev: exec.Device,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    unit: exec.Unit,
    /// The task every request runs on: the openers' copy calls run only
    /// there.
    task: exec.Task,
    stack: ?*anyopaque = null,
    /// The block the MAC and the interrupt reach.
    work: ?*Work = null,
    /// utility.library, for the tag lists OpenDevice is handed.
    utility: ?*UtilityBase = null,
    /// Where the MAC's registers are, as the board's part says.
    mac: usize = 0,
    /// The task's signal the MAC's interrupt raises.
    int_mask: u32 = 0,
    /// For the system time a unit goes online at.
    timer_io: timer.TimeRequest = .{},
    timer_open: u8 = 0,
    /// Whether the interrupt server is hooked up, whether the MAC is
    /// receiving and sending, and whether it takes every frame.
    hooked: u8 = 0,
    running: u8 = 0,
    promiscuous: u8 = 0,
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
    pad: [3]u8 = .{ 0, 0, 0 },
    /// The requests' side of the unit.
    net: Unit,
    /// What the device was loaded from, for its expunge to hand back.
    seg_list: ?*anyopaque = null,

    // --- the unit's link --------------------------------------------------

    pub const bps = ethmac.bps;

    pub fn setStation(base: *OpenethBase, address: *const ethernet.Address) void {
        ethmac.setStation(base.mac, address);
    }

    /// The rings set up afresh and the MAC started, or the MAC stopped
    /// and every write it still had answered.
    pub fn setRunning(base: *OpenethBase, on: bool) void {
        const work = base.work.?;
        if (!on) {
            ethmac.setMode(base.mac, false, base.promiscuous != 0);
            ethmac.setInterrupts(base.mac, 0);
            base.running = 0;
            base.sent();
            while (base.send_busy > 0) base.finishSend(false);
            return;
        }
        ethmac.setSendCount(base.mac, send_count);
        for (0..send_count) |slot| {
            const wrap: u32 = if (slot == send_count - 1) ethmac.txd_wrap else 0;
            ethmac.setDescriptor(base.mac, @intCast(slot), wrap, @intFromPtr(&work.send[slot]));
        }
        for (0..receive_count) |slot| base.giveBack(@intCast(slot));
        base.receive_next = 0;
        base.send_next = 0;
        base.send_done = 0;
        base.send_busy = 0;
        ethmac.setInterrupts(base.mac, ethmac.int_rxb | ethmac.int_txb | ethmac.int_busy);
        ethmac.setMode(base.mac, true, base.promiscuous != 0);
        base.running = 1;
    }

    pub fn setFilter(base: *OpenethBase, groups: []const unit_file.Group, promiscuous: bool) void {
        var hash: u64 = 0;
        for (groups) |group| {
            if (group.users != 0) hash |= @as(u64, 1) << ethmac.groupHash(&group.address);
        }
        ethmac.setGroups(base.mac, hash);
        base.promiscuous = @intFromBool(promiscuous);
        ethmac.setMode(base.mac, base.running != 0, promiscuous);
    }

    /// Every free send descriptor given a write, while there are writes.
    pub fn startWrites(base: *OpenethBase) void {
        const work = base.work.?;
        while (base.running != 0 and base.send_busy < send_count) {
            const req = base.net.nextWrite() orelse return;
            const slot = base.send_next;
            const length = base.net.buildFrame(req, &work.send[slot]);
            if (length == 0) continue;
            base.sending[slot] = req;
            base.send_next = (slot + 1) % send_count;
            base.send_busy += 1;
            const wrap: u32 = if (slot == send_count - 1) ethmac.txd_wrap else 0;
            const flags = length << ethmac.txd_len_shift | ethmac.txd_rd | ethmac.txd_irq |
                ethmac.txd_pad | ethmac.txd_crc | wrap;
            ethmac.setDescriptor(base.mac, slot, flags, @intFromPtr(&work.send[slot]));
        }
    }

    pub fn now(base: *OpenethBase) timer.TimeVal {
        var time: timer.TimeVal = .{};
        if (base.timer_open != 0) {
            const timer_base: *TimerBase = @ptrCast(@alignCast(base.timer_io.node.device.?));
            timer_base.GetSysTime(&time);
        }
        return time;
    }

    // --- the task's side of the rings -------------------------------------

    /// Receive descriptor `slot` handed back to the MAC, empty.
    fn giveBack(base: *OpenethBase, slot: u32) void {
        const wrap: u32 = if (slot == receive_count - 1) ethmac.rxd_wrap else 0;
        ethmac.setDescriptor(base.mac, send_count + slot, ethmac.rxd_e | ethmac.rxd_irq | wrap, @intFromPtr(&base.work.?.receive[slot]));
    }

    /// Every frame the MAC has put in the ring, handed to the unit.
    pub fn received(base: *OpenethBase) void {
        const work = base.work.?;
        while (base.running != 0) {
            const slot = base.receive_next;
            const flags = ethmac.descriptorFlags(base.mac, send_count + slot);
            if (flags & ethmac.rxd_e != 0) return;
            const length = flags >> ethmac.rxd_len_shift;
            if (flags & ethmac.rxd_faults != 0 or length < ethmac.checksum_bytes or length > buffer_bytes) {
                base.net.damaged();
            } else {
                base.net.receive(work.receive[slot][0 .. length - ethmac.checksum_bytes]);
            }
            base.giveBack(slot);
            base.receive_next = (slot + 1) % receive_count;
        }
    }

    /// Every write whose descriptor the MAC has given back, answered, and
    /// the writes that waited for a descriptor started.
    pub fn sent(base: *OpenethBase) void {
        while (base.send_busy > 0) {
            if (ethmac.descriptorFlags(base.mac, base.send_done) & ethmac.txd_rd != 0) break;
            base.finishSend(true);
        }
        base.startWrites();
    }

    fn finishSend(base: *OpenethBase, done: bool) void {
        const slot = base.send_done;
        const req = base.sending[slot].?;
        base.sending[slot] = null;
        base.send_done = (slot + 1) % send_count;
        base.send_busy -= 1;
        base.net.written(req, done);
    }
};

pub fn openethBase(dev: *exec.Device) *OpenethBase {
    return @fieldParentPtr("dev", dev);
}

/// The base of the request's unit.
pub fn baseOf(io: *exec.IORequest) *OpenethBase {
    return @fieldParentPtr("unit", io.unit.?);
}

pub fn sanaReq(io: *exec.IORequest) *net.IOSana2Req {
    return @alignCast(@fieldParentPtr("req", io));
}

/// The request a message on the unit's port belongs to.
pub fn requestOf(msg: *exec.Message) *exec.IORequest {
    return @fieldParentPtr("message", msg);
}
