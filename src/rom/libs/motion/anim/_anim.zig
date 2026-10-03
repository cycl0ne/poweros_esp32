// SPDX-License-Identifier: MPL-2.0
//! What an animation is inside, and its step on the clock.
//!
//! An `Anim` is a `Clocked` (`clock/_clock.zig`) with what its tags said
//! and where it is. Its step works the value out from the time alone -
//! since its start, less its delay, through its plays and its curve - so a
//! late step lands where the animation should be by then, and the last
//! step is put at the very end of the last play rather than a step's
//! length after it.
//!
//! A play lasts `duration`; with play-back it is there and back again in
//! twice that. `repeat` plays, or for ever. The value at a point of a play
//! is `from + (to - from) * eased / one`, in 64 bits and rounded to the
//! nearest.
//!
//! **In a timeline** (`timeline/_timeline.zig`) its start is the timeline's
//! plus its offset, so it keeps with the others. Reversed, its step reads
//! the time mirrored in the timeline: it begins at its end and goes back
//! to its start, and is done when the timeline's time has come back past
//! its beginning. Its end tells the timeline, which is done when the last
//! of its animations is.
//!
//! The owner hears of a step that changes the value, and of the end: its
//! step hook and done hook on the task the step runs on, and its signal.
//! Everything here runs holding the clock's semaphore.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const motion = sdk.motion;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _clock = @import("../clock/_clock.zig");
const _ease = @import("../ease/_ease.zig");
const _timeline = @import("../timeline/_timeline.zig");
const Clocked = _clock.Clocked;
const TagItem = utility.TagItem;

const one: i64 = motion.MOTION_ONE;
const max_value: i64 = 0x7FFF_FFFF;
const min_value: i64 = -0x8000_0000;

/// An animation.
pub const Anim = extern struct {
    clocked: Clocked = .{ .step = &step, .gone = &gone },
    from: i32 = 0,
    to: i32 = 0,
    /// Milliseconds.
    duration: u32 = 250,
    delay: u32 = 0,
    curve: u32 = motion.EASE_LINEAR,
    /// `ANIM_Bezier`'s points, when `has_bezier`.
    bezier: [4]i32 = .{ 0, 0, 0, 0 },
    has_bezier: u32 = 0,
    ease_hook: ?*utility.Hook = null,
    repeat: u32 = 1,
    play_back: u32 = 0,
    step_hook: ?*utility.Hook = null,
    done_hook: ?*utility.Hook = null,
    signal: i32 = -1,
    user_data: usize = 0,
    /// Microseconds between steps.
    interval: u32 = 1_000_000 / 30,
    /// When it was started, in the clock's microseconds.
    start: u64 align(4) = 0,
    /// Where it is: its value, how far through its play, whether it runs,
    /// and whether its owner has heard of a step since it started.
    value: i32 = 0,
    progress: u32 = 0,
    running: u32 = 0,
    told: u32 = 0,
    /// The timeline it is in, its place there, and how long after the
    /// timeline it begins (milliseconds).
    line: ?*_timeline.Line = null,
    in_line: exec.MinNode = .{},
    offset: u32 = 0,
};

pub fn of(animation: *motion.Animation) *Anim {
    return @ptrCast(@alignCast(animation));
}

fn animOf(clocked: *Clocked) *Anim {
    return @fieldParentPtr("clocked", clocked);
}

/// The tags read into `anim`; how many it took. A new end while it runs
/// turns it from where it is now, over the whole duration again.
pub fn setTags(mb: *MotionBase, anim: *Anim, tags: ?[*]const TagItem) u32 {
    const ub = mb.utility_base;
    var taken: u32 = 0;
    var walk: ?[*]const TagItem = tags;
    var new_end = false;
    while (ub.NextTagItem(&walk)) |item| {
        const v = item.data;
        const signed: i32 = @bitCast(@as(u32, @truncate(v)));
        switch (item.tag) {
            motion.ANIM_From => anim.from = signed,
            motion.ANIM_To => {
                anim.to = signed;
                new_end = true;
            },
            motion.ANIM_Duration => anim.duration = @truncate(v),
            motion.ANIM_Delay => anim.delay = @truncate(v),
            motion.ANIM_Easing => {
                anim.curve = @truncate(v);
                anim.has_bezier = 0;
                anim.ease_hook = null;
            },
            motion.ANIM_Bezier => {
                if (v == 0) {
                    anim.has_bezier = 0;
                } else {
                    anim.bezier = @as(*const [4]i32, @ptrFromInt(v)).*;
                    anim.has_bezier = 1;
                    anim.ease_hook = null;
                }
            },
            motion.ANIM_EaseHook => anim.ease_hook = @ptrFromInt(v),
            motion.ANIM_Repeat => anim.repeat = @max(@as(u32, @truncate(v)), 1),
            motion.ANIM_PlayBack => anim.play_back = @intFromBool(v != 0),
            motion.ANIM_StepHook => anim.step_hook = @ptrFromInt(v),
            motion.ANIM_DoneHook => anim.done_hook = @ptrFromInt(v),
            motion.ANIM_Signal => anim.signal = if (signed >= 0 and signed < 32) signed else -1,
            motion.ANIM_UserData => anim.user_data = v,
            motion.ANIM_Rate => {
                const rate: u32 = @max(@min(@as(u32, @truncate(v)), 60), 1);
                anim.interval = 1_000_000 / rate;
            },
            else => continue,
        }
        taken += 1;
    }
    if (new_end and anim.running != 0) {
        // From where it is, the delay already behind it.
        anim.from = anim.value;
        anim.start = _clock.now(mb) -| @as(u64, anim.delay) * 1000;
        anim.clocked.due = _clock.now(mb);
    }
    return taken;
}

/// Where an animation is at a time.
pub const Position = struct {
    begun: bool,
    done: bool,
    progress: u32,
    value: i32,
};

pub fn microseconds(ms: u32) u64 {
    return @as(u64, ms) * 1000;
}

/// One play's length in microseconds: there and back with play-back.
pub fn playLength(anim: *const Anim) u64 {
    const there = @max(microseconds(anim.duration), 1);
    return if (anim.play_back != 0) 2 * there else there;
}

/// When the last play ends, in the clock's microseconds; null for ever.
fn endTime(anim: *const Anim) ?u64 {
    if (anim.repeat == motion.ANIM_FOREVER) return null;
    return anim.start + microseconds(anim.delay) + playLength(anim) * anim.repeat;
}

/// The curve at `progress`: the caller's hook, the Bezier, or an `EASE_`.
fn eased(anim: *Anim, progress: u32) i64 {
    if (anim.ease_hook) |hook| {
        var msg = motion.AnimationMsg{ .kind = motion.ANIMMSG_EASE, .value = anim.value, .progress = progress, .user_data = anim.user_data };
        const answer = hook.entry.?(hook, @ptrCast(anim), &msg);
        return @as(i32, @bitCast(@as(u32, @truncate(answer))));
    }
    if (anim.has_bezier != 0) return _ease.bezier(anim.bezier[0], anim.bezier[1], anim.bezier[2], anim.bezier[3], progress);
    return _ease.at(anim.curve, progress);
}

fn valueAt(anim: *Anim, progress: u32) i32 {
    const span: i64 = @as(i64, anim.to) - anim.from;
    // Rounded to the nearest, a half up: 89.99 is 90.
    const moved = @divFloor(span * eased(anim, progress) + one / 2, one);
    return @intCast(@max(@min(@as(i64, anim.from) + moved, max_value), min_value));
}

/// Where `anim` is at `time`.
pub fn positionAt(anim: *Anim, time: u64) Position {
    const begins = anim.start + microseconds(anim.delay);
    if (time < begins) return .{ .begun = false, .done = false, .progress = 0, .value = anim.from };
    const elapsed = time - begins;
    const there = @max(microseconds(anim.duration), 1);
    const length = playLength(anim);
    const plays = elapsed / length;
    if (anim.repeat != motion.ANIM_FOREVER and plays >= anim.repeat) {
        // The end of the last play: back at the start with play-back.
        const progress: u32 = if (anim.play_back != 0) 0 else @intCast(one);
        return .{ .begun = true, .done = true, .progress = progress, .value = if (anim.play_back != 0) anim.from else anim.to };
    }
    const within = elapsed % length;
    // A play is at most twice 2^32 ms in microseconds; times 2^16 it still
    // fits in 64 bits.
    const progress: u32 = if (within < there)
        @intCast(within * motion.MOTION_ONE / there)
    else
        @intCast(motion.MOTION_ONE - (within - there) * motion.MOTION_ONE / there);
    return .{ .begun = true, .done = false, .progress = progress, .value = valueAt(anim, progress) };
}

/// The owner told: its hook for `kind`, and its signal.
pub fn tell(mb: *MotionBase, anim: *Anim, kind: u32) void {
    const hook = if (kind == motion.ANIMMSG_DONE) anim.done_hook else anim.step_hook;
    if (hook) |h| {
        var msg = motion.AnimationMsg{ .kind = kind, .value = anim.value, .progress = anim.progress, .user_data = anim.user_data };
        _ = h.entry.?(h, @ptrCast(anim), &msg);
    }
    if (anim.signal >= 0) {
        if (anim.clocked.owner) |owner| mb.sys_base.Signal(owner.task, @as(u32, 1) << @intCast(anim.signal));
    }
}

/// Where `anim`, in a reversed timeline, is at `time`: the timeline's time
/// mirrored, so it begins at its end and is done once the time has come
/// back past its beginning.
fn reversedAt(anim: *Anim, line: *const _timeline.Line, time: u64) Position {
    const elapsed = time -| line.start;
    const mirrored = line.start + (line.length -| elapsed);
    const begins = anim.start + microseconds(anim.delay);
    if (elapsed >= line.length or mirrored <= begins) return .{ .begun = true, .done = true, .progress = 0, .value = anim.from };
    const at = positionAt(anim, mirrored);
    return .{ .begun = true, .done = false, .progress = at.progress, .value = at.value };
}

/// The step on the clock.
fn step(mb: *MotionBase, clocked: *Clocked, time: u64) callconv(.c) bool {
    const anim = animOf(clocked);
    const reversed: ?*_timeline.Line = if (anim.line) |line| (if (line.reverse != 0) line else null) else null;
    const at = if (reversed) |line| reversedAt(anim, line, time) else positionAt(anim, time);
    if (!at.begun) {
        clocked.due = anim.start + microseconds(anim.delay);
        return true;
    }
    anim.progress = at.progress;
    if (at.value != anim.value or anim.told == 0) {
        anim.value = at.value;
        anim.told = 1;
        tell(mb, anim, motion.ANIMMSG_STEP);
    }
    if (at.done) {
        anim.running = 0;
        tell(mb, anim, motion.ANIMMSG_DONE);
        if (anim.line) |line| _timeline.memberEnded(mb, line);
        return false;
    }
    // The next step a step's length on, or at once if the clock is behind -
    // but never past the end, so the last one lands on it.
    var next = clocked.due + anim.interval;
    if (next <= time) next = time + anim.interval;
    if (reversed) |line| {
        next = @min(next, line.start + line.length);
    } else if (endTime(anim)) |end| {
        next = @min(next, end);
    }
    clocked.due = next;
    return true;
}

/// The animation run from its start.
pub fn start(mb: *MotionBase, anim: *Anim) void {
    const sys = mb.sys_base;
    sys.ObtainSemaphore(&mb.lock);
    // Started on its own, it leaves its timeline.
    if (anim.line != null) _timeline.detach(mb, anim);
    anim.start = _clock.now(mb);
    anim.value = anim.from;
    anim.progress = 0;
    anim.told = 0;
    anim.running = 1;
    anim.clocked.due = anim.start + microseconds(anim.delay);
    sys.ReleaseSemaphore(&mb.lock);
    _clock.schedule(mb, &anim.clocked);
}

/// The animation stopped, where it is or at its end; told as when it ends.
pub fn stop(mb: *MotionBase, anim: *Anim, where: u32) void {
    const sys = mb.sys_base;
    sys.ObtainSemaphore(&mb.lock);
    defer sys.ReleaseSemaphore(&mb.lock);
    if (anim.running == 0) return;
    _clock.unschedule(mb, &anim.clocked);
    anim.running = 0;
    if (where == motion.STOP_AT_END) {
        const end = if (anim.play_back != 0) anim.from else anim.to;
        anim.progress = if (anim.play_back != 0) 0 else @intCast(one);
        if (end != anim.value) {
            anim.value = end;
            tell(mb, anim, motion.ANIMMSG_STEP);
        }
    }
    tell(mb, anim, motion.ANIMMSG_DONE);
    if (anim.line) |line| _timeline.memberEnded(mb, line);
}

/// Its owner's task ended with it still held: out of its timeline, and
/// freed, untold.
fn gone(mb: *MotionBase, clocked: *Clocked) callconv(.c) void {
    const anim = animOf(clocked);
    _timeline.detach(mb, anim);
    mb.sys_base.FreeVec(anim);
}
