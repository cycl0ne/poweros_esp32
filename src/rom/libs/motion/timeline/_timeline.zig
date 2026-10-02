// SPDX-License-Identifier: MPL-2.0
//! What a timeline is inside: its animations, and the one time they count
//! from.
//!
//! A timeline runs no steps of its own. Started, it gives each of its
//! animations its own start time plus that animation's offset and puts it
//! on the clock: the animations then step as any other does, and keep
//! together because their times all come from the one start. Reversed, an
//! animation reads the time mirrored in the timeline (`anim/_anim.zig`).
//! The timeline's length is the end of its last animation, worked out
//! when it starts; an animation that plays for ever has no end, and is
//! not taken.
//!
//! It is a `Clocked` only to belong to a task: it is never on the clock,
//! and its owner's end frees it. Each of its animations is still its
//! caller's, freed by itself. Everything here holds the clock's semaphore.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const motion = sdk.motion;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _clock = @import("../clock/_clock.zig");
const _anim = @import("../anim/_anim.zig");
const Clocked = _clock.Clocked;
const Anim = _anim.Anim;
const TagItem = utility.TagItem;

/// A timeline.
pub const Line = extern struct {
    clocked: Clocked = .{ .step = &never, .gone = &gone },
    /// Its animations, by their `in_line` node.
    members: exec.MinList = .{},
    /// When it was started, and how long it lasts, in microseconds.
    start: u64 align(4) = 0,
    length: u64 align(4) = 0,
    reverse: u32 = 0,
    running: u32 = 0,
    done_hook: ?*utility.Hook = null,
    signal: i32 = -1,
    user_data: usize = 0,
};

pub fn of(timeline: *motion.Timeline) *Line {
    return @ptrCast(@alignCast(timeline));
}

/// It is never on the clock.
fn never(_: *MotionBase, _: *Clocked, _: u64) callconv(.c) bool {
    return false;
}

/// Its owner's task ended with it still held: its animations let go of,
/// and it freed. An animation that goes first takes itself out, so either
/// order leaves nothing pointing at what is gone.
fn gone(mb: *MotionBase, clocked: *Clocked) callconv(.c) void {
    const line: *Line = @fieldParentPtr("clocked", clocked);
    const sys = mb.sys_base;
    while (sys.RemHead(@ptrCast(&line.members))) |node| {
        const anim: *Anim = @fieldParentPtr("in_line", @as(*exec.MinNode, @ptrCast(node)));
        anim.line = null;
    }
    sys.FreeVec(line);
}

/// Each animation of the timeline in turn.
const Members = struct {
    at: ?*exec.MinNode,

    fn of(line: *Line) Members {
        return .{ .at = line.members.head };
    }

    fn next(members: *Members) ?*Anim {
        const node = members.at orelse return null;
        members.at = node.succ orelse return null;
        return @fieldParentPtr("in_line", node);
    }
};

/// The tags read into `line`; how many it took.
pub fn setTags(mb: *MotionBase, line: *Line, tags: ?[*]const TagItem) u32 {
    var taken: u32 = 0;
    var walk: ?[*]const TagItem = tags;
    while (mb.utility_base.NextTagItem(&walk)) |item| {
        const v = item.data;
        const signed: i32 = @bitCast(@as(u32, @truncate(v)));
        switch (item.tag) {
            motion.TIMELINE_Reverse => line.reverse = @intFromBool(v != 0),
            motion.TIMELINE_DoneHook => line.done_hook = @ptrFromInt(v),
            motion.TIMELINE_Signal => line.signal = if (signed >= 0 and signed < 32) signed else -1,
            motion.TIMELINE_UserData => line.user_data = v,
            else => continue,
        }
        taken += 1;
    }
    return taken;
}

/// `anim` into `line` at `offset` ms; false for one that plays for ever or
/// is in a timeline already.
pub fn add(mb: *MotionBase, line: *Line, anim: *Anim, offset: u32) bool {
    if (anim.line != null or anim.repeat == motion.ANIM_FOREVER) return false;
    anim.line = line;
    anim.offset = offset;
    mb.sys_base.AddTail(@ptrCast(&line.members), @ptrCast(&anim.in_line));
    return true;
}

/// `anim` out of its timeline.
pub fn detach(mb: *MotionBase, anim: *Anim) void {
    if (anim.line == null) return;
    mb.sys_base.Remove(@ptrCast(&anim.in_line));
    anim.line = null;
}

/// Where the last of its animations ends, in microseconds from its start.
fn lengthOf(line: *Line) u64 {
    var length: u64 = 0;
    var members = Members.of(line);
    while (members.next()) |anim| {
        const end = _anim.microseconds(anim.offset) + _anim.microseconds(anim.delay) + _anim.playLength(anim) * anim.repeat;
        length = @max(length, end);
    }
    return length;
}

/// Every animation started from the timeline's start, or its end reversed.
pub fn start(mb: *MotionBase, line: *Line) void {
    const sys = mb.sys_base;
    sys.ObtainSemaphore(&mb.lock);
    defer sys.ReleaseSemaphore(&mb.lock);
    line.start = _clock.now(mb);
    line.length = lengthOf(line);
    line.running = 1;
    var members = Members.of(line);
    while (members.next()) |anim| {
        anim.start = line.start + _anim.microseconds(anim.offset);
        anim.value = if (line.reverse != 0) (if (anim.play_back != 0) anim.from else anim.to) else anim.from;
        anim.progress = 0;
        anim.told = 0;
        anim.running = 1;
        anim.clocked.due = if (line.reverse != 0) line.start else anim.start + _anim.microseconds(anim.delay);
        _clock.schedule(mb, &anim.clocked);
    }
}

/// Every animation stopped, each told as when it ends; the last of them
/// tells the timeline.
pub fn stop(mb: *MotionBase, line: *Line, where: u32) void {
    const sys = mb.sys_base;
    sys.ObtainSemaphore(&mb.lock);
    defer sys.ReleaseSemaphore(&mb.lock);
    var members = Members.of(line);
    while (members.next()) |anim| _anim.stop(mb, anim, where);
    line.running = 0;
}

/// Every animation put where it is `at` ms from the timeline's start, its
/// step hook told when its value moved; the timeline stopped, untold.
pub fn setProgress(mb: *MotionBase, line: *Line, at: u32) void {
    const sys = mb.sys_base;
    sys.ObtainSemaphore(&mb.lock);
    defer sys.ReleaseSemaphore(&mb.lock);
    line.running = 0;
    var members = Members.of(line);
    while (members.next()) |anim| {
        _clock.unschedule(mb, &anim.clocked);
        anim.running = 0;
        anim.start = _anim.microseconds(anim.offset);
        const where = _anim.positionAt(anim, _anim.microseconds(at));
        anim.progress = where.progress;
        if (where.value != anim.value or anim.told == 0) {
            anim.value = where.value;
            anim.told = 1;
            _anim.tell(mb, anim, motion.ANIMMSG_STEP);
        }
    }
}

/// One of its animations ended: the timeline too, when none still runs.
pub fn memberEnded(mb: *MotionBase, line: *Line) void {
    if (line.running == 0) return;
    var members = Members.of(line);
    while (members.next()) |anim| {
        if (anim.running != 0) return;
    }
    line.running = 0;
    if (line.done_hook) |hook| {
        var msg = motion.AnimationMsg{ .kind = motion.ANIMMSG_DONE, .value = 0, .progress = 0, .user_data = line.user_data };
        _ = hook.entry.?(hook, @ptrCast(line), &msg);
    }
    if (line.signal >= 0) {
        if (line.clocked.owner) |owner| mb.sys_base.Signal(owner.task, @as(u32, 1) << @intCast(line.signal));
    }
}

/// Every animation stopped untold and let go of.
pub fn empty(mb: *MotionBase, line: *Line) void {
    const sys = mb.sys_base;
    sys.ObtainSemaphore(&mb.lock);
    defer sys.ReleaseSemaphore(&mb.lock);
    while (sys.RemHead(@ptrCast(&line.members))) |node| {
        const anim: *Anim = @fieldParentPtr("in_line", @as(*exec.MinNode, @ptrCast(node)));
        _clock.unschedule(mb, &anim.clocked);
        anim.running = 0;
        anim.line = null;
    }
    line.running = 0;
}
