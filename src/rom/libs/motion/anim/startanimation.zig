// SPDX-License-Identifier: MPL-2.0
//! StartAnimation: an animation run from its start.

const sdk = @import("sdk");
const motion = sdk.motion;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _anim = @import("_anim.zig");

/// An animation run from its start.
///
/// SYNOPSIS:
/// ```zig
/// fn StartAnimation(mb: *MotionBase, animation: *Animation) void
/// ```
///
/// SINCE: 1.2. LVO -36.
///
/// INPUTS:
/// - `animation` - one from `CreateAnimationTagList`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The value goes back to `ANIM_From` and the animation's time starts now:
/// after its delay its first step runs, and its owner hears of it even
/// though the value has not moved yet. One that runs already starts again
/// from the beginning; one that ended runs again.
///
/// The first time anything is started, motion.library's task is made.
///
/// CONTEXT:
/// - Waits: for the clock's semaphore, while a step runs.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// To turn a running animation towards a new end without going back to
/// its start, set `ANIM_To` (`SetAnimationAttrsTagList`) instead.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StopAnimation`, `SetAnimationAttrsTagList`
///
/// EXAMPLES:
/// ```zig
/// mb.StartAnimation(fill);
/// ```
pub fn StartAnimation(mb: *MotionBase, animation: *motion.Animation) void {
    _anim.start(mb, _anim.of(animation));
}
