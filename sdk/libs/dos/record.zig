// SPDX-License-Identifier: MIT
//! Record locks: a range of an open file's bytes held shared or exclusive
//! (LockRecord, LockRecords, UnLockRecord, UnLockRecords), and what a
//! handler needs to answer them.
//!
//! **A program** locks `length` bytes from `offset` through one of its
//! handles. The locks are cooperative: they keep other record locks out,
//! not Read or Write. An exclusive lock keeps every other handle's locks
//! off its bytes; shared locks share them. A handle never stands in its own
//! way - it may lock the same bytes as often as it likes, in either mode -
//! and each lock is given back by an UnLockRecord with the same offset and
//! length. Closing a handle gives back every lock it still holds.
//!
//! **A lock that cannot be had at once** waits up to its timeout, in ticks
//! of 1/50 s, for the bytes to come free. An `_IMMED` mode does not wait
//! (ERROR_LOCK_COLLISION), and a timeout of 0 is ERROR_LOCK_TIMEOUT at
//! once. As locks go, the waiting ones are tried again in the order they
//! asked.
//!
//! **The handler's side** is `Records`, one per volume. The handler hands
//! it LOCK_RECORD and FREE_RECORD with the object the handle has open and
//! the handle's owner - something that is the handle's alone while it is
//! open, such as the handler's lock behind it - and tells it when a handle
//! is closed. It keeps the held ranges, keeps a waiting packet unanswered
//! with a timer of its own, and answers it when the bytes come free or the
//! time runs out. timer.device is opened when the first lock waits; the
//! timers come back on a port of its own, which the handler waits on
//! beside its packets.

const exec = @import("../exec/exec.zig");
const dosextens = @import("dosextens.zig");
const timer = @import("../../devices/timer.zig");
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const DosBase = @import("../../interface/dos.zig").DosBase;
const dos = @import("dos.zig");
const FileHandle = dosextens.FileHandle;
const DosPacket = dosextens.DosPacket;

/// LockRecord's modes. EXCLUSIVE keeps every other handle's locks off the
/// bytes, SHARED only the exclusive ones; the `_IMMED` forms do not wait.
pub const REC_EXCLUSIVE: u32 = 0;
pub const REC_EXCLUSIVE_IMMED: u32 = 1;
pub const REC_SHARED: u32 = 2;
pub const REC_SHARED_IMMED: u32 = 3;

/// struct RecordLock: one record of LockRecords' and UnLockRecords' array,
/// which ends at the first entry without a handle. The array is the
/// program's; it hands the same one to both calls.
pub const RecordLock = extern struct {
    /// rec_FH: the handle; null ends the array.
    fh: ?*FileHandle = null,
    /// rec_Offset: where the record starts in the file.
    offset: u64 align(4) = 0,
    /// rec_Length: its bytes.
    length: u64 align(4) = 0,
    /// rec_Mode: REC_*.
    mode: u32 = REC_EXCLUSIVE,
};

// --- the handler's side -------------------------------------------------------------

/// A range of an object's bytes, who holds or wants it, and how. Kept
/// together and handed on by address: the 64-bit offset and length do
/// not all fit the registers a call is given.
const Range = struct {
    object: *anyopaque,
    owner: *anyopaque,
    offset: u64,
    length: u64,
    mode: u32,

    /// Whether the two share a byte: [offset, offset + length), the end
    /// held at the last byte a 64-bit offset can say.
    fn overlaps(range: *const Range, other: *const Range) bool {
        return range.offset < other.offset +| other.length and other.offset < range.offset +| range.length;
    }

    /// Whether the two cannot both be held: different owners' ranges
    /// over the same bytes of one object, either of them exclusive.
    fn conflicts(range: *const Range, other: *const Range) bool {
        if (range.object != other.object or range.owner == other.owner) return false;
        if (!range.overlaps(other)) return false;
        return exclusive(range.mode) or exclusive(other.mode);
    }
};

/// A range held.
const Held = struct {
    node: exec.Node = .{},
    range: Range,
};

/// A LOCK_RECORD that waits: its packet, kept unanswered, the range it
/// wants, and the timer that ends the wait.
const Waiter = struct {
    node: exec.Node = .{},
    packet: *DosPacket,
    range: Range,
    clock: timer.TimeRequest = .{},
};

/// What LOCK_RECORD came to: the range held, refused with the error for
/// dp_Res2, or waiting - the packet is the table's now, and is answered
/// when the bytes come free or the time runs out.
pub const Outcome = union(enum) {
    granted,
    refused: i32,
    waiting,
};

/// A volume's record locks.
pub const Records = struct {
    sys: *ExecBase,
    dl: *DosBase,
    /// Where the waiters' timers come back to.
    port: ?*exec.MsgPort = null,
    /// A request opened on timer.device, which each waiter's timer is
    /// copied from; open once the first lock has waited.
    clock: timer.TimeRequest = .{},
    clock_open: bool = false,
    held: exec.List = .{},
    waiting: exec.List = .{},

    /// Ready to take locks: false without a port for the timers.
    pub fn init(r: *Records, sys: *ExecBase, dl: *DosBase) bool {
        r.* = .{ .sys = sys, .dl = dl };
        r.held.init(.unknown);
        r.waiting.init(.unknown);
        r.port = sys.CreateMsgPort() orelse return false;
        return true;
    }

    /// Every range dropped, every waiter answered ERROR_INVALID_LOCK, the
    /// timer closed and the port deleted - for a handler that ends.
    pub fn deinit(r: *Records) void {
        const sys = r.sys;
        while (r.waiting.first()) |node| r.answer(@alignCast(@fieldParentPtr("node", node)), dos.ERROR_INVALID_LOCK);
        while (r.held.first()) |node| {
            sys.Remove(node);
            sys.FreeVec(node);
        }
        if (r.clock_open) sys.CloseDevice(&r.clock.node);
        r.clock_open = false;
        if (r.port) |port| sys.DeleteMsgPort(port);
        r.port = null;
    }

    /// The signal of the port the timers come back to, for the handler's
    /// Wait.
    pub fn signals(r: *Records) u32 {
        const port = r.port orelse return 0;
        return port.sigMask();
    }

    /// LOCK_RECORD: the packet's range of `object` held by `owner`, if no
    /// other owner holds a range over it that the mode cannot share. When
    /// it cannot be had at once, a mode that waits keeps the packet and
    /// the handler leaves it unanswered.
    pub fn lock(r: *Records, packet: *DosPacket, object: *anyopaque, owner: *anyopaque) Outcome {
        const sys = r.sys;
        const args = packet.args.lock_record;
        if (args.mode > REC_SHARED_IMMED) return .{ .refused = dos.ERROR_BAD_NUMBER };
        const want: Range = .{ .object = object, .owner = owner, .offset = args.offset, .length = args.length, .mode = @intCast(args.mode) };
        if (r.free(&want)) return if (r.hold(&want)) .granted else .{ .refused = dos.ERROR_NO_FREE_STORE };
        if (want.mode & 1 != 0) return .{ .refused = dos.ERROR_LOCK_COLLISION };
        const ticks: u32 = @truncate(args.timeout);
        if (ticks == 0) return .{ .refused = dos.ERROR_LOCK_TIMEOUT };
        if (!r.openClock()) return .{ .refused = dos.ERROR_NO_FREE_STORE };
        const memory = sys.AllocVec(@sizeOf(Waiter), exec.MEMF_CLEAR) orelse return .{ .refused = dos.ERROR_NO_FREE_STORE };
        const waiter: *Waiter = @ptrCast(@alignCast(memory));
        waiter.* = .{ .packet = packet, .range = want, .clock = r.clock };
        waiter.clock.node.command = timer.TR_ADDREQUEST;
        waiter.clock.time = timer.TimeVal.fromMicros(@as(u64, ticks) * TICK_MICROS);
        sys.AddTail(&r.waiting, &waiter.node);
        sys.SendIO(&waiter.clock.node);
        return .waiting;
    }

    /// FREE_RECORD: one range `owner` holds on `object` at exactly the
    /// packet's offset and length given back, and the waiters tried
    /// again. False when it holds none such (ERROR_RECORD_NOT_LOCKED).
    pub fn unlock(r: *Records, packet: *DosPacket, object: *anyopaque, owner: *anyopaque) bool {
        const sys = r.sys;
        const args = packet.args.free_record;
        var it = r.held.iterator();
        while (it.next()) |node| {
            const held: *Held = @alignCast(@fieldParentPtr("node", node));
            const range = &held.range;
            if (range.object != object or range.owner != owner or range.offset != args.offset or range.length != args.length) continue;
            sys.Remove(node);
            sys.FreeVec(held);
            r.wake(object);
            return true;
        }
        return false;
    }

    /// A handle closed: every range its owner holds given back, a lock
    /// it still waits for answered ERROR_INVALID_LOCK, and the waiters
    /// tried again.
    pub fn release(r: *Records, owner: *anyopaque) void {
        const sys = r.sys;
        var waiters = r.waiting.iterator();
        while (waiters.next()) |node| {
            const waiter: *Waiter = @alignCast(@fieldParentPtr("node", node));
            if (waiter.range.owner == owner) r.answer(waiter, dos.ERROR_INVALID_LOCK);
        }
        var released = false;
        var it = r.held.iterator();
        while (it.next()) |node| {
            const held: *Held = @alignCast(@fieldParentPtr("node", node));
            if (held.range.owner != owner) continue;
            sys.Remove(node);
            sys.FreeVec(held);
            released = true;
        }
        if (released) r.wakeAll();
    }

    /// The timers that came back: their waiters answered ERROR_LOCK_TIMEOUT.
    pub fn collect(r: *Records) void {
        const sys = r.sys;
        const port = r.port orelse return;
        while (sys.GetMsg(port)) |message| {
            const clock: *timer.TimeRequest = @ptrCast(@alignCast(message));
            const waiter: *Waiter = @alignCast(@fieldParentPtr("clock", clock));
            sys.Remove(&waiter.node);
            r.dl.ReplyPkt(waiter.packet, dos.DOSFALSE, dos.ERROR_LOCK_TIMEOUT);
            sys.FreeVec(waiter);
        }
    }

    /// How many ranges are held, for the tests.
    pub fn heldCount(r: *Records) usize {
        var count: usize = 0;
        var it = r.held.iterator();
        while (it.next()) |_| count += 1;
        return count;
    }

    /// Whether the range wanted may be had: nothing held conflicts with
    /// it.
    fn free(r: *Records, want: *const Range) bool {
        var it = r.held.iterator();
        while (it.next()) |node| {
            const held: *Held = @alignCast(@fieldParentPtr("node", node));
            if (held.range.conflicts(want)) return false;
        }
        return true;
    }

    fn hold(r: *Records, want: *const Range) bool {
        const sys = r.sys;
        const memory = sys.AllocVec(@sizeOf(Held), exec.MEMF_CLEAR) orelse return false;
        const held: *Held = @ptrCast(@alignCast(memory));
        held.* = .{ .range = want.* };
        sys.AddTail(&r.held, &held.node);
        return true;
    }

    /// The waiters on `object` tried again, in the order they asked: each
    /// that can have its range now holds it and is answered.
    fn wake(r: *Records, object: *anyopaque) void {
        var it = r.waiting.iterator();
        while (it.next()) |node| {
            const waiter: *Waiter = @alignCast(@fieldParentPtr("node", node));
            if (waiter.range.object == object) r.retry(waiter);
        }
    }

    fn wakeAll(r: *Records) void {
        var it = r.waiting.iterator();
        while (it.next()) |node| r.retry(@alignCast(@fieldParentPtr("node", node)));
    }

    fn retry(r: *Records, waiter: *Waiter) void {
        if (!r.free(&waiter.range)) return;
        if (r.hold(&waiter.range)) {
            r.answer(waiter, 0);
        } else {
            r.answer(waiter, dos.ERROR_NO_FREE_STORE);
        }
    }

    /// A waiter done with: its timer stopped, its packet answered - DOSTRUE
    /// for `code` 0, else DOSFALSE with it - and freed.
    fn answer(r: *Records, waiter: *Waiter, code: i32) void {
        const sys = r.sys;
        _ = sys.AbortIO(&waiter.clock.node);
        _ = sys.WaitIO(&waiter.clock.node);
        sys.Remove(&waiter.node);
        r.dl.ReplyPkt(waiter.packet, if (code == 0) dos.DOSTRUE else dos.DOSFALSE, code);
        sys.FreeVec(waiter);
    }

    fn openClock(r: *Records) bool {
        if (r.clock_open) return true;
        const port = r.port orelse return false;
        r.clock = .{ .node = .{ .message = .{ .reply_port = port, .length = @sizeOf(timer.TimeRequest) } } };
        if (r.sys.OpenDevice(timer.TIMERNAME, timer.UNIT_VBLANK, &r.clock.node, 0) != 0) return false;
        r.clock_open = true;
        return true;
    }
};

/// A tick's microseconds: timeouts count fiftieths of a second.
const TICK_MICROS: u64 = 20_000;

fn exclusive(mode: u32) bool {
    return mode <= REC_EXCLUSIVE_IMMED;
}
