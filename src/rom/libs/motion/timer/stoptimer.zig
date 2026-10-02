// SPDX-License-Identifier: MPL-2.0
//! StopTimer: a timer stopped.

const sdk = @import("sdk");
const motion = sdk.motion;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _timer = @import("_timer.zig");

/// A timer stopped.
///
/// SYNOPSIS:
/// ```zig
/// fn StopTimer(mb: *MotionBase, timer: *Timer) void
/// ```
///
/// SINCE: 1.3. LVO -72.
///
/// INPUTS:
/// - `timer` - one from `CreateTimerTagList`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Taken off the clock, untold: once this returns its hook is not running
/// and will not run until it is started again. Nothing for one that is not
/// running.
///
/// CONTEXT:
/// - Waits: for the clock's semaphore, while a step runs.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands; the timer can be started again.
///
/// NOTES:
/// A signal it sent before it was stopped may still be waiting for the
/// owner: clear it with `SetSignal` before waiting on it again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartTimer`, `DeleteTimer`
///
/// EXAMPLES:
/// ```zig
/// mb.StopTimer(blink);
/// ```
pub fn StopTimer(mb: *MotionBase, timer: *motion.Timer) void {
    _timer.stop(mb, _timer.of(timer));
}
