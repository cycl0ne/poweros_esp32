// SPDX-License-Identifier: MPL-2.0
//! What a timer is inside, and its step on the clock.
//!
//! A `Tick` is a `Clocked` with a period, a first delay and a count. It
//! fires at its start plus its delay, then a period after each firing it
//! was due for - so it does not drift - and a firing the clock was too
//! late for is not made up: after a late one the next is the next that has
//! not passed. Its owner hears of each through its hook, on the clock's
//! task, and its signal. Everything here runs holding the clock's
//! semaphore.

const sdk = @import("sdk");
const utility = sdk.utility;
const motion = sdk.motion;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _clock = @import("../clock/_clock.zig");
const Clocked = _clock.Clocked;
const TagItem = utility.TagItem;

/// A timer.
pub const Tick = extern struct {
    clocked: Clocked = .{ .step = &step, .gone = &gone },
    /// Milliseconds; `delay` of 0xFFFFFFFF is the period.
    period: u32 = 1000,
    delay: u32 = 0xFFFF_FFFF,
    repeat: u32 = 1,
    hook: ?*utility.Hook = null,
    signal: i32 = -1,
    user_data: usize = 0,
    count: u32 = 0,
    running: u32 = 0,
};

pub fn of(timer: *motion.Timer) *Tick {
    return @ptrCast(@alignCast(timer));
}

fn tickOf(clocked: *Clocked) *Tick {
    return @fieldParentPtr("clocked", clocked);
}

/// The tags read into `tick`.
pub fn setTags(mb: *MotionBase, tick: *Tick, tags: ?[*]const TagItem) void {
    var walk: ?[*]const TagItem = tags;
    while (mb.utility_base.NextTagItem(&walk)) |item| {
        const v = item.data;
        const signed: i32 = @bitCast(@as(u32, @truncate(v)));
        switch (item.tag) {
            motion.TIMER_Period => tick.period = @max(@as(u32, @truncate(v)), 1),
            motion.TIMER_Delay => tick.delay = @truncate(v),
            motion.TIMER_Repeat => tick.repeat = @max(@as(u32, @truncate(v)), 1),
            motion.TIMER_Hook => tick.hook = @ptrFromInt(v),
            motion.TIMER_Signal => tick.signal = if (signed >= 0 and signed < 32) signed else -1,
            motion.TIMER_UserData => tick.user_data = v,
            else => {},
        }
    }
}

fn microseconds(ms: u32) u64 {
    return @as(u64, ms) * 1000;
}

/// A firing: counted, and the owner told.
fn step(mb: *MotionBase, clocked: *Clocked, time: u64) callconv(.c) bool {
    const tick = tickOf(clocked);
    tick.count += 1;
    const last = tick.repeat != motion.TIMER_FOREVER and tick.count >= tick.repeat;
    if (last) tick.running = 0;
    if (tick.hook) |hook| {
        var msg = motion.TimerMsg{ .count = tick.count, .last = @intFromBool(last), .user_data = tick.user_data };
        _ = hook.entry.?(hook, @ptrCast(tick), &msg);
    }
    if (tick.signal >= 0) {
        if (clocked.owner) |owner| mb.sys_base.Signal(owner.task, @as(u32, 1) << @intCast(tick.signal));
    }
    if (last) return false;
    // A period on from when it was due; past ones are not made up.
    const period = microseconds(tick.period);
    var next = clocked.due + period;
    if (next <= time) next += ((time - next) / period + 1) * period;
    clocked.due = next;
    return true;
}

/// Started from now.
pub fn start(mb: *MotionBase, tick: *Tick) void {
    const sys = mb.sys_base;
    sys.ObtainSemaphore(&mb.lock);
    tick.count = 0;
    tick.running = 1;
    const first = if (tick.delay == 0xFFFF_FFFF) tick.period else tick.delay;
    tick.clocked.due = _clock.now(mb) + microseconds(first);
    sys.ReleaseSemaphore(&mb.lock);
    _clock.schedule(mb, &tick.clocked);
}

/// Stopped, untold.
pub fn stop(mb: *MotionBase, tick: *Tick) void {
    const sys = mb.sys_base;
    sys.ObtainSemaphore(&mb.lock);
    defer sys.ReleaseSemaphore(&mb.lock);
    _clock.unschedule(mb, &tick.clocked);
    tick.running = 0;
}

/// Its owner's task ended with it still held: freed, untold.
fn gone(mb: *MotionBase, clocked: *Clocked) callconv(.c) void {
    mb.sys_base.FreeVec(tickOf(clocked));
}
