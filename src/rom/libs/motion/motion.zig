// SPDX-License-Identifier: MPL-2.0
//! motion.library: a clock for things that move.
//!
//! One task with one timer.device request runs every animation and timer
//! that is due (`clock/_clock.zig`). The task is made the first time
//! something is due; while nothing is, no request is out and it sleeps.
//! Each call is a file of its own in a folder per area. The jump table is
//! motion_lvo.zig, the ROM tag and init motion_init.zig, the base
//! motion_base.zig. This file holds the names the rest of the kernel
//! reaches the library by, and the tests of it working as a whole.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;

const motion_base = @import("motion_base.zig");
const motion_init = @import("motion_init.zig");
const _clock = @import("clock/_clock.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from motion.library.
comptime {
    _ = &motion_init.motion_library_tag;
}

/// The library's base.
pub const MotionBase = motion_base.MotionBase;
/// What the library is on exec's list as.
pub const LIBRARY_NAME = motion_init.LIBRARY_NAME;
/// The ROM tag, for the host tests that make the library from it.
pub const motion_library_tag = motion_init.motion_library_tag;

// --- tests ------------------------------------------------------------------------

const testing = std.testing;
const kexec = @import("../exec/exec.zig");
const Clocked = _clock.Clocked;

test {
    _ = motion_base;
    _ = motion_init;
    _ = @import("motion_lvo.zig");
    _ = _clock;
}

fn setUp() !*MotionBase {
    try kexec.setUp();
    const made = kexec.InitResident(kexec.SysBase, &motion_library_tag, null) orelse return error.NoMotion;
    return @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
}

fn tearDown(mb: *MotionBase) !void {
    kexec.Remove(kexec.SysBase, &mb.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &mb.lib);
    try kexec.expectNoLeaks();
}

/// Something on the clock that counts its steps and, every `period`, runs
/// again until it has run `times` times.
const Counter = struct {
    clocked: Clocked = .{ .step = &step },
    period: u64,
    times: u32,
    ran: u32 = 0,
    last: u64 = 0,

    fn step(_: *MotionBase, clocked: *Clocked, now: u64) callconv(.c) bool {
        const counter: *Counter = @fieldParentPtr("clocked", clocked);
        counter.ran += 1;
        counter.last = now;
        if (counter.ran >= counter.times) return false;
        clocked.due += counter.period;
        return true;
    }
};

test "the clock: nothing due is nothing to wake for, and no task without timer.device" {
    const mb = try setUp();
    defer kexec.deinit();
    try testing.expectEqual(@as(?u64, null), _clock.advance(mb, 0));
    var counter = Counter{ .period = 0, .times = 1 };
    counter.clocked.due = 10;
    _clock.schedule(mb, &counter.clocked);
    // Tried and given up: there is no clock to run it on.
    try testing.expectEqual(@as(u32, 2), mb.started);
    try testing.expectEqual(@as(u64, 0), mb.hand_time);
    try testing.expectEqual(@as(u64, 0), _clock.now(mb));
    _clock.unschedule(mb, &counter.clocked);
    try tearDown(mb);
}

test "the clock: each step when it is due, the earliest next time answered, the done ones taken off" {
    const mb = try setUp();
    defer kexec.deinit();
    var every = Counter{ .period = 100, .times = 3 };
    every.clocked.due = 100;
    var once = Counter{ .period = 0, .times = 1 };
    once.clocked.due = 250;
    _clock.schedule(mb, &every.clocked);
    _clock.schedule(mb, &once.clocked);

    // Before anything is due: nothing runs, and the first is next.
    try testing.expectEqual(@as(?u64, 100), _clock.advance(mb, 50));
    try testing.expectEqual(@as(u32, 0), every.ran);

    // A late step lands where it is: run at 130, next due a period after
    // the time it was due, not after the time it ran.
    try testing.expectEqual(@as(?u64, 200), _clock.advance(mb, 130));
    try testing.expectEqual(@as(u32, 1), every.ran);
    try testing.expectEqual(@as(u64, 130), every.last);

    // Both at once, the one-off taken off after its step.
    try testing.expectEqual(@as(?u64, 300), _clock.advance(mb, 260));
    try testing.expectEqual(@as(u32, 2), every.ran);
    try testing.expectEqual(@as(u32, 1), once.ran);
    try testing.expectEqual(@as(u32, 0), once.clocked.queued);

    // The last of the three, and nothing left.
    try testing.expectEqual(@as(?u64, null), _clock.advance(mb, 300));
    try testing.expectEqual(@as(u32, 3), every.ran);
    try testing.expectEqual(@as(u32, 0), every.clocked.queued);
    try tearDown(mb);
}

test "the clock: taken off before its time, it never runs; put on twice, it is there once" {
    const mb = try setUp();
    defer kexec.deinit();
    var counter = Counter{ .period = 10, .times = 5 };
    counter.clocked.due = 20;
    _clock.schedule(mb, &counter.clocked);
    _clock.schedule(mb, &counter.clocked);
    try testing.expectEqual(@as(?u64, 20), _clock.advance(mb, 0));
    _clock.unschedule(mb, &counter.clocked);
    _clock.unschedule(mb, &counter.clocked);
    try testing.expectEqual(@as(?u64, null), _clock.advance(mb, 1000));
    try testing.expectEqual(@as(u32, 0), counter.ran);
    try tearDown(mb);
}

/// A step that takes another off the clock and puts a third on.
const Juggler = struct {
    clocked: Clocked = .{ .step = &step },
    drop: *Clocked,
    add: *Clocked,

    fn step(mb: *MotionBase, clocked: *Clocked, _: u64) callconv(.c) bool {
        const juggler: *Juggler = @fieldParentPtr("clocked", clocked);
        _clock.unschedule(mb, juggler.drop);
        _clock.schedule(mb, juggler.add);
        return false;
    }
};

test "the clock: a step may take others off and put others on" {
    const mb = try setUp();
    defer kexec.deinit();
    var dropped = Counter{ .period = 10, .times = 5 };
    dropped.clocked.due = 100;
    var added = Counter{ .period = 10, .times = 1 };
    added.clocked.due = 70;
    var juggler = Juggler{ .drop = &dropped.clocked, .add = &added.clocked };
    juggler.clocked.due = 50;
    _clock.schedule(mb, &juggler.clocked);
    _clock.schedule(mb, &dropped.clocked);
    try testing.expectEqual(@as(?u64, 70), _clock.advance(mb, 60));
    try testing.expectEqual(@as(u32, 0), dropped.clocked.queued);
    try testing.expectEqual(@as(?u64, null), _clock.advance(mb, 70));
    try testing.expectEqual(@as(u32, 1), added.ran);
    try testing.expectEqual(@as(u32, 0), dropped.ran);
    try tearDown(mb);
}

/// Something on the clock that counts the times it was let go.
const Held = struct {
    clocked: Clocked = .{ .step = &step, .gone = &goneFn },
    gone: u32 = 0,

    fn step(_: *MotionBase, _: *Clocked, _: u64) callconv(.c) bool {
        return true;
    }

    fn goneFn(_: *MotionBase, clocked: *Clocked) callconv(.c) void {
        const held: *Held = @fieldParentPtr("clocked", clocked);
        held.gone += 1;
    }
};

fn idle(_: *sdk.interface.exec.ExecBase) callconv(.c) void {}

test "the clock: what a task still holds when it ends is taken off and let go; what it gave back is not" {
    const mb = try setUp();
    defer kexec.deinit();
    var task: exec.Task = .{ .node = .{ .name = "holder", .pri = -1 } };
    _ = kexec.AddTask(kexec.SysBase, &task, &idle, null);

    var running = Held{};
    running.clocked.due = 100;
    var stopped = Held{};
    var given_back = Held{};
    try testing.expect(_clock.adopt(mb, &running.clocked, &task));
    try testing.expect(_clock.adopt(mb, &stopped.clocked, &task));
    try testing.expect(_clock.adopt(mb, &given_back.clocked, &task));
    _clock.schedule(mb, &running.clocked);
    _clock.release(mb, &given_back.clocked);
    // One owner for the task, however much it holds.
    try testing.expect(mb.owners.head.?.succ.?.succ == null);

    kexec.RemTask(kexec.SysBase, &task);
    try testing.expectEqual(@as(u32, 1), running.gone);
    try testing.expectEqual(@as(u32, 1), stopped.gone);
    try testing.expectEqual(@as(u32, 0), given_back.gone);
    try testing.expectEqual(@as(u32, 0), running.clocked.queued);
    try testing.expectEqual(@as(?u64, null), _clock.advance(mb, 1000));
    // The owner went with the task.
    try testing.expect(mb.owners.head.?.succ == null);
    try tearDown(mb);
}

test "the clock: a task that gives back all it held has no hook left to run" {
    const mb = try setUp();
    defer kexec.deinit();
    var task: exec.Task = .{ .node = .{ .name = "tidy", .pri = -1 } };
    _ = kexec.AddTask(kexec.SysBase, &task, &idle, null);
    var held = Held{};
    try testing.expect(_clock.adopt(mb, &held.clocked, &task));
    _clock.release(mb, &held.clocked);
    try testing.expect(task.end_hooks.head.?.succ == null);
    kexec.RemTask(kexec.SysBase, &task);
    try testing.expectEqual(@as(u32, 0), held.gone);
    try tearDown(mb);
}
