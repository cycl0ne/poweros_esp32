// SPDX-License-Identifier: MPL-2.0
//! StopAnimation: an animation stopped, where it is or at its end.

const sdk = @import("sdk");
const motion = sdk.motion;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _anim = @import("_anim.zig");

/// An animation stopped.
///
/// SYNOPSIS:
/// ```zig
/// fn StopAnimation(mb: *MotionBase, animation: *Animation, where: u32) void
/// ```
///
/// SINCE: 1.2. LVO -40.
///
/// INPUTS:
/// - `animation` - one from `CreateAnimationTagList`.
/// - `where` - `STOP_WHERE_IT_IS`, or `STOP_AT_END` to put the value at
///   the end of its last play first (`ANIM_To`, or `ANIM_From` with
///   play-back).
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// It is taken off the clock and its owner told as when it ends by
/// itself: with `STOP_AT_END` a last step if the value moves, then its
/// done hook and its signal - on the caller's task. Nothing for one that
/// is not running.
///
/// CONTEXT:
/// - Waits: for the clock's semaphore, while a step runs.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands; the animation can be started again.
///
/// NOTES:
/// What a gadget does when it is told a value straight away: the
/// animation that was moving it ends where the value now is.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartAnimation`, `DeleteAnimation`
///
/// EXAMPLES:
/// ```zig
/// mb.StopAnimation(fill, motion.STOP_AT_END);
/// ```
pub fn StopAnimation(mb: *MotionBase, animation: *motion.Animation, where: u32) void {
    _anim.stop(mb, _anim.of(animation), where);
}
