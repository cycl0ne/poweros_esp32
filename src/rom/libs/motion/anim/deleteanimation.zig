// SPDX-License-Identifier: MPL-2.0
//! DeleteAnimation: an animation stopped and freed.

const sdk = @import("sdk");
const motion = sdk.motion;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _clock = @import("../clock/_clock.zig");
const _anim = @import("_anim.zig");
const _timeline = @import("../timeline/_timeline.zig");

/// An animation stopped where it is and freed.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteAnimation(mb: *MotionBase, animation: ?*Animation) void
/// ```
///
/// SINCE: 1.2. LVO -32.
///
/// INPUTS:
/// - `animation` - one from `CreateAnimationTagList`, running or not, or
///   null.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A running animation is taken off the clock first, and out of its
/// timeline; nobody is told. Once
/// this returns its step is not running and will not run again, so what
/// its hooks reach may go too.
///
/// CONTEXT:
/// - Waits: for the clock's semaphore, while a step of any animation runs.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The animation's memory goes back to the system.
///
/// NOTES:
/// Called from a hook of the animation itself - its done hook, say - it
/// is freed under the hook's feet: let the hook signal its owner instead.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateAnimationTagList`, `StopAnimation`
///
/// EXAMPLES:
/// ```zig
/// mb.DeleteAnimation(fill);
/// ```
pub fn DeleteAnimation(mb: *MotionBase, animation: ?*motion.Animation) void {
    const anim = _anim.of(animation orelse return);
    const sys = mb.sys_base;
    sys.ObtainSemaphore(&mb.lock);
    _timeline.detach(mb, anim);
    sys.ReleaseSemaphore(&mb.lock);
    _clock.unschedule(mb, &anim.clocked);
    _clock.release(mb, &anim.clocked);
    mb.sys_base.FreeVec(anim);
}
