// SPDX-License-Identifier: MPL-2.0
//! GetAnimationAttr: one of an animation's attributes.

const sdk = @import("sdk");
const motion = sdk.motion;
const utility = sdk.utility;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _anim = @import("_anim.zig");

/// One of an animation's attributes: where it is, or what it was told.
///
/// SYNOPSIS:
/// ```zig
/// fn GetAnimationAttr(mb: *MotionBase, animation: *Animation, attr: Tag) usize
/// ```
///
/// SINCE: 1.2. LVO -48.
///
/// INPUTS:
/// - `animation` - one from `CreateAnimationTagList`.
/// - `attr` - `ANIM_Value` (i32), `ANIM_Progress` (16.16, before the
///   curve), `ANIM_Running` (bool), or one of the tags it is made with.
///
/// RESULT:
/// The attribute; signed ones as their bits. 0 for a tag it does not know.
///
/// BEHAVIOR:
/// The value is the one its last step worked out: what a program woken by
/// the animation's signal draws.
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
/// `ANIM_Bezier` answers 0: its points are copied in, not kept as the
/// caller's pointer.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetAnimationAttrsTagList`, `CreateAnimationTagList`
///
/// EXAMPLES:
/// ```zig
/// const level: i32 = @bitCast(@as(u32, @truncate(mb.GetAnimationAttr(fill, motion.ANIM_Value))));
/// ```
pub fn GetAnimationAttr(mb: *MotionBase, animation: *motion.Animation, attr: utility.Tag) usize {
    const sys = mb.sys_base;
    const anim = _anim.of(animation);
    sys.ObtainSemaphore(&mb.lock);
    defer sys.ReleaseSemaphore(&mb.lock);
    return switch (attr) {
        motion.ANIM_Value => @as(u32, @bitCast(anim.value)),
        motion.ANIM_Progress => anim.progress,
        motion.ANIM_Running => anim.running,
        motion.ANIM_From => @as(u32, @bitCast(anim.from)),
        motion.ANIM_To => @as(u32, @bitCast(anim.to)),
        motion.ANIM_Duration => anim.duration,
        motion.ANIM_Delay => anim.delay,
        motion.ANIM_Easing => anim.curve,
        motion.ANIM_EaseHook => @intFromPtr(anim.ease_hook),
        motion.ANIM_Repeat => anim.repeat,
        motion.ANIM_PlayBack => anim.play_back,
        motion.ANIM_StepHook => @intFromPtr(anim.step_hook),
        motion.ANIM_DoneHook => @intFromPtr(anim.done_hook),
        motion.ANIM_Signal => @as(u32, @bitCast(anim.signal)),
        motion.ANIM_UserData => anim.user_data,
        motion.ANIM_Rate => 1_000_000 / anim.interval,
        else => 0,
    };
}
