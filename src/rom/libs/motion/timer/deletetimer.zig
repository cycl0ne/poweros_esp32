// SPDX-License-Identifier: MPL-2.0
//! DeleteTimer: a timer stopped and freed.

const sdk = @import("sdk");
const motion = sdk.motion;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _clock = @import("../clock/_clock.zig");
const _timer = @import("_timer.zig");

/// A timer stopped and freed.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteTimer(mb: *MotionBase, timer: ?*Timer) void
/// ```
///
/// SINCE: 1.3. LVO -64.
///
/// INPUTS:
/// - `timer` - one from `CreateTimerTagList`, running or not, or null.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A running timer is taken off the clock first, untold. Once this returns
/// its hook is not running and will not run again.
///
/// CONTEXT:
/// - Waits: for the clock's semaphore, while a step of anything runs.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The timer's memory goes back to the system.
///
/// NOTES:
/// Not from the timer's own hook: it would be freed under the hook.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateTimerTagList`, `StopTimer`
///
/// EXAMPLES:
/// ```zig
/// mb.DeleteTimer(blink);
/// ```
pub fn DeleteTimer(mb: *MotionBase, timer: ?*motion.Timer) void {
    const tick = _timer.of(timer orelse return);
    _clock.unschedule(mb, &tick.clocked);
    _clock.release(mb, &tick.clocked);
    mb.sys_base.FreeVec(tick);
}
