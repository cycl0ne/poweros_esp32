// SPDX-License-Identifier: MPL-2.0
//! SetAnimationAttrsTagList: an animation's tags changed.

const sdk = @import("sdk");
const motion = sdk.motion;
const TagItem = sdk.utility.TagItem;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _clock = @import("../clock/_clock.zig");
const _anim = @import("_anim.zig");

/// An animation's tags changed, running or not.
///
/// SYNOPSIS:
/// ```zig
/// fn SetAnimationAttrsTagList(mb: *MotionBase, animation: *Animation,
///     tags: ?[*]const TagItem) u32
/// ```
///
/// SINCE: 1.2. LVO -44.
///
/// INPUTS:
/// - `animation` - one from `CreateAnimationTagList`.
/// - `tags` - any of the tags it was made with.
///
/// RESULT:
/// How many of the tags it took.
///
/// BEHAVIOR:
/// **A new `ANIM_To` while it runs** turns it towards the new end from
/// where its value is now, over its whole duration again and with its
/// delay behind it: a bar told a new level twice in a row turns towards
/// the second without a jump. Anything else takes effect from its next
/// step - a new curve or duration from the point the time has reached.
///
/// CONTEXT:
/// - Waits: for the clock's semaphore, while a step runs.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Hooks named stay the caller's, and must stay valid while the
/// animation does.
///
/// NOTES:
/// A new `ANIM_From` while it runs moves where its curve starts from, not
/// where the value is: the next step may jump.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateAnimationTagList`, `GetAnimationAttr`
///
/// EXAMPLES:
/// ```zig
/// _ = mb.SetAnimationAttrsTagList(fill, &[_]TagItem{
///     .{ .tag = motion.ANIM_To, .data = 35 },
///     .{},
/// });
/// ```
pub fn SetAnimationAttrsTagList(mb: *MotionBase, animation: *motion.Animation, tags: ?[*]const TagItem) u32 {
    const sys = mb.sys_base;
    const anim = _anim.of(animation);
    sys.ObtainSemaphore(&mb.lock);
    const taken = _anim.setTags(mb, anim, tags);
    sys.ReleaseSemaphore(&mb.lock);
    // A turned animation steps at once, from where it is.
    if (anim.running != 0) _clock.schedule(mb, &anim.clocked);
    return taken;
}
