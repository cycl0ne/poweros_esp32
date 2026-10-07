// SPDX-License-Identifier: MPL-2.0
//! CreateTimerTagList: a timer, from its tags.

const sdk = @import("sdk");
const exec = sdk.exec;
const motion = sdk.motion;
const TagItem = sdk.utility.TagItem;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _clock = @import("../clock/_clock.zig");
const _timer = @import("_timer.zig");

/// A timer: something that fires after a time, or every so often.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateTimerTagList(mb: *MotionBase, tags: ?[*]const TagItem) ?*Timer
/// ```
///
/// SINCE: 1.3. LVO -60.
///
/// INPUTS:
/// - `tags` - what it is, or null for the defaults:
///   - `TIMER_Period` (ms) - between firings (1000).
///   - `TIMER_Delay` (ms) - from `StartTimer` to the first (the period).
///   - `TIMER_Repeat` - how many times it fires (1), `TIMER_FOREVER`.
///   - `TIMER_Hook`, `TIMER_Signal`, `TIMER_UserData` - how its owner
///     hears of a firing.
///
/// RESULT:
/// The timer, not running; null without the memory.
///
/// BEHAVIOR:
/// It belongs to the calling task: if the task ends without deleting it,
/// it is stopped and freed then.
///
/// It fires a period after each firing it was due for, so it does not
/// drift however late a firing comes. A firing the clock was too late for
/// is not made up: after a late one, the next is the next that has not
/// passed. **Its hook** runs on motion.library's task, holding the
/// clock's semaphore: quick, and waiting for nothing another task may hold
/// while it starts or stops a timer.
///
/// CONTEXT:
/// - Waits: for the clock's semaphore, while a step runs, to put it in the
///   calling task's keeping.
/// - Interrupts: no.
/// - Locks: takes the clock's semaphore; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The timer is the caller's until `DeleteTimer`. A hook named must stay
/// valid for as long as it does.
///
/// NOTES:
/// A cursor that blinks, a key or an arrow that repeats while held, a
/// poll: what each would otherwise send a `timer.device` request of its
/// own for. Every timer and animation shares one request.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartTimer`, `StopTimer`, `DeleteTimer`, `CreateAnimationTagList`
///
/// EXAMPLES:
/// ```zig
/// // A cursor that blinks twice a second, for as long as it is shown.
/// const blink = mb.CreateTimerTagList(&[_]TagItem{
///     .{ .tag = motion.TIMER_Period, .data = 500 },
///     .{ .tag = motion.TIMER_Repeat, .data = motion.TIMER_FOREVER },
///     .{ .tag = motion.TIMER_Signal, .data = @intCast(bit) },
///     .{},
/// }) orelse return;
/// mb.StartTimer(blink);
/// ```
pub fn CreateTimerTagList(mb: *MotionBase, tags: ?[*]const TagItem) ?*motion.Timer {
    const sys = mb.sys_base;
    const memory = sys.AllocVec(@sizeOf(_timer.Tick), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const tick: *_timer.Tick = @ptrCast(@alignCast(memory));
    tick.* = .{};
    _timer.setTags(mb, tick, tags);
    if (!_clock.adopt(mb, &tick.clocked, null)) {
        sys.FreeVec(memory);
        return null;
    }
    return @ptrCast(tick);
}
