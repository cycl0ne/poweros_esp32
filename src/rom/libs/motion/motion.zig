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
const kutility = @import("../utility/utility.zig");
const Clocked = _clock.Clocked;

test {
    _ = motion_base;
    _ = motion_init;
    _ = @import("motion_lvo.zig");
    _ = _clock;
    _ = @import("ease/_ease.zig");
    _ = @import("anim/_anim.zig");
    _ = @import("timer/_timer.zig");
    _ = @import("timeline/_timeline.zig");
}

fn setUp() !*MotionBase {
    try kexec.setUp();
    _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
    const made = kexec.InitResident(kexec.SysBase, &motion_library_tag, null) orelse return error.NoMotion;
    return @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
}

fn tearDown(mb: *MotionBase) !void {
    const ub: *kutility.UtilityBase = @ptrCast(@alignCast(mb.utility_base));
    _ = kexec.CloseLibrary(kexec.SysBase, &ub.lib);
    kexec.Remove(kexec.SysBase, &mb.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &mb.lib);
    kutility.freeForTests(ub);
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

const motion = sdk.motion;
const Ease = @import("ease/ease.zig").Ease;
const EaseBezier = @import("ease/easebezier.zig").EaseBezier;
const one: i32 = motion.MOTION_ONE;

test "easing: every curve starts at 0 and ends at exactly 1, and past either end is that end" {
    const mb = try setUp();
    defer kexec.deinit();
    const curves = [_]u32{ motion.EASE_LINEAR, motion.EASE_IN, motion.EASE_OUT, motion.EASE_INOUT, motion.EASE_OVERSHOOT, motion.EASE_BOUNCE, motion.EASE_STEP, 99 };
    for (curves) |curve| {
        try testing.expectEqual(@as(i32, 0), Ease(mb, curve, 0));
        try testing.expectEqual(one, Ease(mb, curve, motion.MOTION_ONE));
        try testing.expectEqual(one, Ease(mb, curve, 3 * motion.MOTION_ONE));
    }
    try tearDown(mb);
}

test "easing: the cubics where they should be, and the ones that only go forwards do" {
    const mb = try setUp();
    defer kexec.deinit();
    const half = motion.MOTION_ONE / 2;
    try testing.expectEqual(@as(i32, @intCast(half)), Ease(mb, motion.EASE_LINEAR, half));
    try testing.expectEqual(one / 8, Ease(mb, motion.EASE_IN, half));
    try testing.expectEqual(one - one / 8, Ease(mb, motion.EASE_OUT, half));
    try testing.expectEqual(one / 2, Ease(mb, motion.EASE_INOUT, half));
    try testing.expectEqual(@as(i32, 0), Ease(mb, motion.EASE_STEP, motion.MOTION_ONE - 1));
    for ([_]u32{ motion.EASE_LINEAR, motion.EASE_IN, motion.EASE_OUT, motion.EASE_INOUT }) |curve| {
        var last: i32 = 0;
        var progress: u32 = 0;
        while (progress <= motion.MOTION_ONE) : (progress += 512) {
            const now = Ease(mb, curve, progress);
            try testing.expect(now >= last);
            last = now;
        }
    }
    try tearDown(mb);
}

test "easing: the overshoot goes past the end and back; the bounce comes down to the floor three times" {
    const mb = try setUp();
    defer kexec.deinit();
    var highest: i32 = 0;
    var falls: u32 = 0;
    var last: i32 = 0;
    var rising = true;
    var progress: u32 = 0;
    while (progress <= motion.MOTION_ONE) : (progress += 256) {
        highest = @max(highest, Ease(mb, motion.EASE_OVERSHOOT, progress));
        const now = Ease(mb, motion.EASE_BOUNCE, progress);
        if (rising and now < last) falls += 1;
        rising = now >= last;
        last = now;
    }
    // About ten percent past the end.
    try testing.expect(highest > one + one / 20 and highest < one + one / 7);
    try testing.expectEqual(@as(u32, 3), falls);
    try tearDown(mb);
}

test "easing: a Bezier with the line's own control points is the line; the usual gentle one where it is known to be" {
    const mb = try setUp();
    defer kexec.deinit();
    var progress: u32 = 0;
    while (progress <= motion.MOTION_ONE) : (progress += 4096) {
        const eased = EaseBezier(mb, 0, 0, one, one, progress);
        try testing.expect(@abs(eased - @as(i32, @intCast(progress))) <= 2);
    }
    // (0.25, 0.1), (0.25, 1.0) at a half is 0.8024.
    const gentle = EaseBezier(mb, one / 4, one / 10, one / 4, one, motion.MOTION_ONE / 2);
    try testing.expect(@abs(gentle - 52586) <= 64);
    try testing.expectEqual(one, EaseBezier(mb, one / 4, one / 10, one / 4, one, motion.MOTION_ONE));
    try tearDown(mb);
}

const utility = sdk.utility;
const TagItem = utility.TagItem;
const CreateAnimationTagList = @import("anim/createanimationtaglist.zig").CreateAnimationTagList;
const DeleteAnimation = @import("anim/deleteanimation.zig").DeleteAnimation;
const StartAnimation = @import("anim/startanimation.zig").StartAnimation;
const StopAnimation = @import("anim/stopanimation.zig").StopAnimation;
const SetAnimationAttrsTagList = @import("anim/setanimationattrstaglist.zig").SetAnimationAttrsTagList;
const GetAnimationAttr = @import("anim/getanimationattr.zig").GetAnimationAttr;
const MixColour = @import("mix/mixcolour.zig").MixColour;
const MixRect = @import("mix/mixrect.zig").MixRect;

/// What an animation's hooks were told.
const Heard = struct {
    step_hook: utility.Hook = .{ .entry = &heard },
    done_hook: utility.Hook = .{ .entry = &heard },
    steps: u32 = 0,
    dones: u32 = 0,
    last: i32 = 0,

    fn heard(hook: *utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
        const msg: *const motion.AnimationMsg = @ptrCast(@alignCast(message.?));
        const self: *Heard = @ptrCast(@alignCast(hook.data.?));
        if (msg.kind == motion.ANIMMSG_DONE) self.dones += 1 else self.steps += 1;
        self.last = msg.value;
        return 0;
    }

    fn tags(self: *Heard) [2]TagItem {
        self.step_hook.data = self;
        self.done_hook.data = self;
        return .{
            .{ .tag = motion.ANIM_StepHook, .data = @intFromPtr(&self.step_hook) },
            .{ .tag = motion.ANIM_DoneHook, .data = @intFromPtr(&self.done_hook) },
        };
    }
};

fn valueOf(mb: *MotionBase, animation: *motion.Animation) i32 {
    return @bitCast(@as(u32, @truncate(GetAnimationAttr(mb, animation, motion.ANIM_Value))));
}

/// A linear one from 0 to 100 in 100 ms, its hooks into `heard`.
fn hundred(mb: *MotionBase, heard: *Heard, more: []const TagItem) !*motion.Animation {
    const hooks = heard.tags();
    var tags: [8]TagItem = undefined;
    tags[0] = .{ .tag = motion.ANIM_To, .data = 100 };
    tags[1] = .{ .tag = motion.ANIM_Duration, .data = 100 };
    tags[2] = hooks[0];
    tags[3] = hooks[1];
    for (more, 0..) |item, i| tags[4 + i] = item;
    tags[4 + more.len] = .{};
    return CreateAnimationTagList(mb, &tags) orelse error.NoAnimation;
}

test "animations: from start to end on the clock's time, the owner told of each step that moves and of the end" {
    const mb = try setUp();
    defer kexec.deinit();
    var heard = Heard{};
    const anim = try hundred(mb, &heard, &.{});
    mb.hand_time = 0;
    StartAnimation(mb, anim);
    try testing.expectEqual(@as(usize, 1), GetAnimationAttr(mb, anim, motion.ANIM_Running));
    // The first step tells, though nothing has moved yet.
    _ = _clock.advance(mb, 0);
    try testing.expectEqual(@as(u32, 1), heard.steps);
    try testing.expectEqual(@as(i32, 0), heard.last);
    // A late step lands where the time says, and the next is put no later
    // than the end.
    try testing.expectEqual(@as(?u64, 100_000), _clock.advance(mb, 90_000));
    try testing.expectEqual(@as(i32, 90), valueOf(mb, anim));
    try testing.expectEqual(@as(u32, 2), heard.steps);
    // The end: exactly the end value, the done hook once, and off the clock.
    try testing.expectEqual(@as(?u64, null), _clock.advance(mb, 100_000));
    try testing.expectEqual(@as(i32, 100), valueOf(mb, anim));
    try testing.expectEqual(@as(u32, 1), heard.dones);
    try testing.expectEqual(@as(usize, 0), GetAnimationAttr(mb, anim, motion.ANIM_Running));
    DeleteAnimation(mb, anim);
    try tearDown(mb);
}

test "animations: a delay, a repeat there and back, and a step that does not move tells nobody" {
    const mb = try setUp();
    defer kexec.deinit();
    var heard = Heard{};
    const anim = try hundred(mb, &heard, &.{
        .{ .tag = motion.ANIM_Delay, .data = 20 },
        .{ .tag = motion.ANIM_Repeat, .data = 2 },
        .{ .tag = motion.ANIM_PlayBack, .data = 1 },
    });
    mb.hand_time = 1_000_000;
    StartAnimation(mb, anim);
    // In its delay: nothing, and the clock told when it begins.
    try testing.expectEqual(@as(?u64, 1_020_000), _clock.advance(mb, 1_010_000));
    try testing.expectEqual(@as(u32, 0), heard.steps);
    // Half way back in the first play: 150 ms after it began.
    _ = _clock.advance(mb, 1_170_000);
    try testing.expectEqual(@as(i32, 50), valueOf(mb, anim));
    const told = heard.steps;
    _ = _clock.advance(mb, 1_170_000);
    try testing.expectEqual(told, heard.steps);
    // Two plays of 200 ms each, ending where it began.
    try testing.expectEqual(@as(?u64, null), _clock.advance(mb, 1_420_000));
    try testing.expectEqual(@as(i32, 0), valueOf(mb, anim));
    try testing.expectEqual(@as(u32, 1), heard.dones);
    DeleteAnimation(mb, anim);
    try tearDown(mb);
}

test "animations: a new end while running turns from where it is; stopped at the end is told as an end" {
    const mb = try setUp();
    defer kexec.deinit();
    var heard = Heard{};
    const anim = try hundred(mb, &heard, &.{});
    mb.hand_time = 0;
    StartAnimation(mb, anim);
    _ = _clock.advance(mb, 50_000);
    try testing.expectEqual(@as(i32, 50), valueOf(mb, anim));
    // Back to 0 from 50, over the whole 100 ms again.
    mb.hand_time = 50_000;
    try testing.expectEqual(@as(u32, 1), SetAnimationAttrsTagList(mb, anim, &[_]TagItem{ .{ .tag = motion.ANIM_To, .data = 0 }, .{} }));
    _ = _clock.advance(mb, 100_000);
    try testing.expectEqual(@as(i32, 25), valueOf(mb, anim));
    StopAnimation(mb, anim, motion.STOP_AT_END);
    try testing.expectEqual(@as(i32, 0), valueOf(mb, anim));
    try testing.expectEqual(@as(u32, 1), heard.dones);
    // Stopping one that is not running is nothing.
    StopAnimation(mb, anim, motion.STOP_AT_END);
    try testing.expectEqual(@as(u32, 1), heard.dones);
    try testing.expectEqual(@as(?u64, null), _clock.advance(mb, 1_000_000));
    DeleteAnimation(mb, anim);
    try tearDown(mb);
}

test "animations: a signal to the owner, a curve, a Bezier, and deleted while it runs" {
    const mb = try setUp();
    defer kexec.deinit();
    const me = kexec.SysBase.cpu().this_task;
    const bit = kexec.AllocSignal(kexec.SysBase, -1);
    defer kexec.FreeSignal(kexec.SysBase, bit);
    const points = [4]i32{ one / 4, one / 10, one / 4, one };
    const anim = CreateAnimationTagList(mb, &[_]TagItem{
        .{ .tag = motion.ANIM_To, .data = 1000 },
        .{ .tag = motion.ANIM_Duration, .data = 100 },
        .{ .tag = motion.ANIM_Bezier, .data = @intFromPtr(&points) },
        .{ .tag = motion.ANIM_Signal, .data = @intCast(bit) },
        .{},
    }).?;
    mb.hand_time = 0;
    StartAnimation(mb, anim);
    me.sig_recvd &= ~(@as(u32, 1) << @intCast(bit));
    _ = _clock.advance(mb, 50_000);
    try testing.expect(me.sig_recvd & (@as(u32, 1) << @intCast(bit)) != 0);
    // The gentle curve at half its time is 0.8024 of the way.
    try testing.expect(@abs(valueOf(mb, anim) - 802) <= 1);
    DeleteAnimation(mb, anim);
    try testing.expectEqual(@as(?u64, null), _clock.advance(mb, 60_000));
    try tearDown(mb);
}

test "mixing: colours channel by channel, boxes edge by edge, held where a channel would run over" {
    const mb = try setUp();
    defer kexec.deinit();
    try testing.expectEqual(@as(u32, 0xFFAAAAAA), MixColour(mb, 0xFFAAAAAA, 0xFF3A6EA5, 0));
    try testing.expectEqual(@as(u32, 0xFF3A6EA5), MixColour(mb, 0xFFAAAAAA, 0xFF3A6EA5, motion.MOTION_ONE));
    try testing.expectEqual(@as(u32, 0x80408000), MixColour(mb, 0xFF000000, 0x0080FF00, motion.MOTION_ONE / 2));
    try testing.expectEqual(@as(u32, 0xFF0000FF), MixColour(mb, 0xFF000080, 0xFF0000FF, 2 * motion.MOTION_ONE));
    var box: sdk.graphics.Rect = undefined;
    MixRect(mb, &.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, &.{ .min_x = 100, .min_y = 50, .max_x = 300, .max_y = 70 }, motion.MOTION_ONE / 2, &box);
    try testing.expectEqual(sdk.graphics.Rect{ .min_x = 50, .min_y = 25, .max_x = 155, .max_y = 40 }, box);
    try tearDown(mb);
}

const CreateTimerTagList = @import("timer/createtimertaglist.zig").CreateTimerTagList;
const DeleteTimer = @import("timer/deletetimer.zig").DeleteTimer;
const StartTimer = @import("timer/starttimer.zig").StartTimer;
const StopTimer = @import("timer/stoptimer.zig").StopTimer;

/// What a timer's hook was told.
const Fired = struct {
    hook: utility.Hook = .{ .entry = &fired },
    times: u32 = 0,
    count: u32 = 0,
    last: u32 = 0,

    fn fired(hook: *utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
        const msg: *const motion.TimerMsg = @ptrCast(@alignCast(message.?));
        const self: *Fired = @ptrCast(@alignCast(hook.data.?));
        self.times += 1;
        self.count = msg.count;
        self.last = msg.last;
        return 0;
    }
};

test "timers: once after its delay; every period without drift; a late firing not made up" {
    const mb = try setUp();
    defer kexec.deinit();
    var once = Fired{};
    once.hook.data = &once;
    const single = CreateTimerTagList(mb, &[_]TagItem{
        .{ .tag = motion.TIMER_Period, .data = 100 },
        .{ .tag = motion.TIMER_Hook, .data = @intFromPtr(&once.hook) },
        .{},
    }).?;
    var every = Fired{};
    every.hook.data = &every;
    const repeating = CreateTimerTagList(mb, &[_]TagItem{
        .{ .tag = motion.TIMER_Period, .data = 100 },
        .{ .tag = motion.TIMER_Delay, .data = 10 },
        .{ .tag = motion.TIMER_Repeat, .data = motion.TIMER_FOREVER },
        .{ .tag = motion.TIMER_Hook, .data = @intFromPtr(&every.hook) },
        .{},
    }).?;
    mb.hand_time = 0;
    StartTimer(mb, single);
    StartTimer(mb, repeating);
    // The repeating one first, at its delay; then each a period on from
    // when it was due, though the clock comes late.
    try testing.expectEqual(@as(?u64, 100_000), _clock.advance(mb, 15_000));
    try testing.expectEqual(@as(u32, 1), every.times);
    try testing.expectEqual(@as(?u64, 110_000), _clock.advance(mb, 100_000));
    try testing.expectEqual(@as(u32, 1), once.times);
    try testing.expectEqual(@as(u32, 1), once.last);
    // 300 ms late: one firing, and the next is the next still to come.
    try testing.expectEqual(@as(?u64, 510_000), _clock.advance(mb, 420_000));
    try testing.expectEqual(@as(u32, 2), every.times);
    try testing.expectEqual(@as(u32, 2), every.count);
    try testing.expectEqual(@as(u32, 0), every.last);
    // Stopped: nothing more; started again, its count from 0.
    StopTimer(mb, repeating);
    try testing.expectEqual(@as(?u64, null), _clock.advance(mb, 600_000));
    mb.hand_time = 600_000;
    StartTimer(mb, repeating);
    _ = _clock.advance(mb, 610_000);
    try testing.expectEqual(@as(u32, 1), every.count);
    DeleteTimer(mb, single);
    DeleteTimer(mb, repeating);
    try testing.expectEqual(@as(?u64, null), _clock.advance(mb, 2_000_000));
    try tearDown(mb);
}

const CreateTimelineTagList = @import("timeline/createtimelinetaglist.zig").CreateTimelineTagList;
const DeleteTimeline = @import("timeline/deletetimeline.zig").DeleteTimeline;
const AddTimelineAnimation = @import("timeline/addtimelineanimation.zig").AddTimelineAnimation;
const StartTimeline = @import("timeline/starttimeline.zig").StartTimeline;
const StopTimeline = @import("timeline/stoptimeline.zig").StopTimeline;
const SetTimelineProgress = @import("timeline/settimelineprogress.zig").SetTimelineProgress;
const SetTimelineAttrsTagList = @import("timeline/settimelineattrstaglist.zig").SetTimelineAttrsTagList;

/// Two animations in a timeline: 0 to 100 at once, 0 to 10 50 ms later,
/// each 100 ms.
const Pair = struct {
    first: *motion.Animation,
    second: *motion.Animation,
    line: *motion.Timeline,
    heard: Heard = .{},
    line_done: utility.Hook = .{ .entry = &Heard.heard },

    fn make(mb: *MotionBase, pair: *Pair) !void {
        pair.first = CreateAnimationTagList(mb, &[_]TagItem{
            .{ .tag = motion.ANIM_To, .data = 100 },
            .{ .tag = motion.ANIM_Duration, .data = 100 },
            .{},
        }).?;
        pair.second = CreateAnimationTagList(mb, &[_]TagItem{
            .{ .tag = motion.ANIM_To, .data = 10 },
            .{ .tag = motion.ANIM_Duration, .data = 100 },
            .{},
        }).?;
        pair.line_done.data = &pair.heard;
        pair.line = CreateTimelineTagList(mb, &[_]TagItem{
            .{ .tag = motion.TIMELINE_DoneHook, .data = @intFromPtr(&pair.line_done) },
            .{},
        }).?;
        try testing.expect(AddTimelineAnimation(mb, pair.line, pair.first, 0));
        try testing.expect(AddTimelineAnimation(mb, pair.line, pair.second, 50));
    }

    fn free(mb: *MotionBase, pair: *Pair) void {
        DeleteTimeline(mb, pair.line);
        DeleteAnimation(mb, pair.first);
        DeleteAnimation(mb, pair.second);
    }
};

test "timelines: two animations kept together from one start, the timeline told when the last ends" {
    const mb = try setUp();
    defer kexec.deinit();
    var pair: Pair = undefined;
    pair = .{ .first = undefined, .second = undefined, .line = undefined };
    try Pair.make(mb, &pair);
    mb.hand_time = 0;
    StartTimeline(mb, pair.line);
    _ = _clock.advance(mb, 75_000);
    try testing.expectEqual(@as(i32, 75), valueOf(mb, pair.first));
    try testing.expectEqual(@as(i32, 3), valueOf(mb, pair.second));
    _ = _clock.advance(mb, 100_000);
    try testing.expectEqual(@as(u32, 0), pair.heard.dones);
    try testing.expectEqual(@as(?u64, null), _clock.advance(mb, 150_000));
    try testing.expectEqual(@as(i32, 100), valueOf(mb, pair.first));
    try testing.expectEqual(@as(i32, 10), valueOf(mb, pair.second));
    try testing.expectEqual(@as(u32, 1), pair.heard.dones);
    Pair.free(mb, &pair);
    try tearDown(mb);
}

test "timelines: reversed, each from its end back to its start, the last to begin the first to go back" {
    const mb = try setUp();
    defer kexec.deinit();
    var pair: Pair = .{ .first = undefined, .second = undefined, .line = undefined };
    try Pair.make(mb, &pair);
    try testing.expectEqual(@as(u32, 1), SetTimelineAttrsTagList(mb, pair.line, &[_]TagItem{ .{ .tag = motion.TIMELINE_Reverse, .data = 1 }, .{} }));
    mb.hand_time = 1_000_000;
    StartTimeline(mb, pair.line);
    _ = _clock.advance(mb, 1_000_000);
    try testing.expectEqual(@as(i32, 100), valueOf(mb, pair.first));
    try testing.expectEqual(@as(i32, 10), valueOf(mb, pair.second));
    _ = _clock.advance(mb, 1_050_000);
    try testing.expectEqual(@as(i32, 100), valueOf(mb, pair.first));
    try testing.expectEqual(@as(i32, 5), valueOf(mb, pair.second));
    _ = _clock.advance(mb, 1_100_000);
    try testing.expectEqual(@as(i32, 50), valueOf(mb, pair.first));
    try testing.expectEqual(@as(i32, 0), valueOf(mb, pair.second));
    try testing.expectEqual(@as(?u64, null), _clock.advance(mb, 1_150_000));
    try testing.expectEqual(@as(i32, 0), valueOf(mb, pair.first));
    try testing.expectEqual(@as(u32, 1), pair.heard.dones);
    Pair.free(mb, &pair);
    try tearDown(mb);
}

test "timelines: scrubbed to a point, stopped at the end, and what may not join" {
    const mb = try setUp();
    defer kexec.deinit();
    var pair: Pair = .{ .first = undefined, .second = undefined, .line = undefined };
    try Pair.make(mb, &pair);
    SetTimelineProgress(mb, pair.line, 75);
    try testing.expectEqual(@as(i32, 75), valueOf(mb, pair.first));
    try testing.expectEqual(@as(i32, 3), valueOf(mb, pair.second));
    try testing.expectEqual(@as(?u64, null), _clock.advance(mb, 5_000_000));
    mb.hand_time = 0;
    StartTimeline(mb, pair.line);
    StopTimeline(mb, pair.line, motion.STOP_AT_END);
    try testing.expectEqual(@as(i32, 100), valueOf(mb, pair.first));
    try testing.expectEqual(@as(i32, 10), valueOf(mb, pair.second));
    try testing.expectEqual(@as(u32, 1), pair.heard.dones);
    // In a timeline already; for ever.
    try testing.expect(!AddTimelineAnimation(mb, pair.line, pair.first, 0));
    const endless = CreateAnimationTagList(mb, &[_]TagItem{ .{ .tag = motion.ANIM_Repeat, .data = motion.ANIM_FOREVER }, .{} }).?;
    try testing.expect(!AddTimelineAnimation(mb, pair.line, endless, 0));
    DeleteAnimation(mb, endless);
    // An animation deleted before its timeline takes itself out.
    DeleteAnimation(mb, pair.second);
    DeleteTimeline(mb, pair.line);
    DeleteAnimation(mb, pair.first);
    try tearDown(mb);
}

test "timelines: a task that ends holding a timeline and its animations frees them all, in either order" {
    for ([_]bool{ true, false }) |line_first| {
        const mb = try setUp();
        defer kexec.deinit();
        var task: exec.Task = .{ .node = .{ .name = "holder", .pri = -1 } };
        _ = kexec.AddTask(kexec.SysBase, &task, &idle, null);
        var pair: Pair = .{ .first = undefined, .second = undefined, .line = undefined };
        try Pair.make(mb, &pair);
        // Made the other task's, in one order or the other.
        const timeline_clocked = &@import("timeline/_timeline.zig").of(pair.line).clocked;
        const first = &@import("anim/_anim.zig").of(pair.first).clocked;
        const second = &@import("anim/_anim.zig").of(pair.second).clocked;
        const order = if (line_first) [_]*Clocked{ timeline_clocked, first, second } else [_]*Clocked{ first, second, timeline_clocked };
        for (order) |clocked| {
            _clock.release(mb, clocked);
            try testing.expect(_clock.adopt(mb, clocked, &task));
        }
        mb.hand_time = 0;
        StartTimeline(mb, pair.line);
        kexec.RemTask(kexec.SysBase, &task);
        try testing.expectEqual(@as(?u64, null), _clock.advance(mb, 1_000_000));
        try tearDown(mb);
    }
}
