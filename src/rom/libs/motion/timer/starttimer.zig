// SPDX-License-Identifier: MPL-2.0
//! StartTimer: a timer started from now.

const sdk = @import("sdk");
const motion = sdk.motion;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _timer = @import("_timer.zig");

/// A timer started from now.
///
/// SYNOPSIS:
/// ```zig
/// fn StartTimer(mb: *MotionBase, timer: *Timer) void
/// ```
///
/// SINCE: 1.3. LVO -68.
///
/// INPUTS:
/// - `timer` - one from `CreateTimerTagList`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Its first firing comes its delay from now, its count starting from 0.
/// One that runs already starts again from now; one that has fired all
/// its times runs again.
///
/// CONTEXT:
/// - Waits: for the clock's semaphore, while a step runs.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// Starting it again is how a timeout is pushed back: an inactivity timer
/// started anew at each key never fires while keys come.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StopTimer`, `CreateTimerTagList`
///
/// EXAMPLES:
/// ```zig
/// mb.StartTimer(blink);
/// ```
pub fn StartTimer(mb: *MotionBase, timer: *motion.Timer) void {
    _timer.start(mb, _timer.of(timer));
}
