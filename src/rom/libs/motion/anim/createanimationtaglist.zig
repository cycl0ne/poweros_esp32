// SPDX-License-Identifier: MPL-2.0
//! CreateAnimationTagList: an animation, from its tags.

const sdk = @import("sdk");
const exec = sdk.exec;
const motion = sdk.motion;
const TagItem = sdk.utility.TagItem;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _clock = @import("../clock/_clock.zig");
const _anim = @import("_anim.zig");

/// An animation: a value going from one number to another over a time.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateAnimationTagList(mb: *MotionBase, tags: ?[*]const TagItem) ?*Animation
/// ```
///
/// SINCE: 1.2. LVO -28.
///
/// INPUTS:
/// - `tags` - what it is, or null for the defaults:
///   - `ANIM_From`, `ANIM_To` (i32) - where the value starts and ends (0).
///   - `ANIM_Duration` (ms) - one play (250); `ANIM_Delay` (ms) - before
///     it begins (0).
///   - `ANIM_Easing` (`EASE_`, `EASE_LINEAR`), or `ANIM_Bezier` (four
///     16.16 control points, copied), or `ANIM_EaseHook` (a curve of the
///     caller's own).
///   - `ANIM_Repeat` - plays (1), `ANIM_FOREVER` for ever;
///     `ANIM_PlayBack` - each play there and back.
///   - `ANIM_StepHook`, `ANIM_DoneHook`, `ANIM_Signal`, `ANIM_UserData` -
///     how its owner hears of it.
///   - `ANIM_Rate` - steps a second, 1 to 60 (30).
///
/// RESULT:
/// The animation, not running; null without the memory.
///
/// BEHAVIOR:
/// It belongs to the calling task: if the task ends without deleting it,
/// it is stopped and freed then, and nobody is told.
///
/// A step works the value out from the time alone, so a step that comes
/// late - a busy system - lands where the animation should be by then, and
/// it ends when it should. A step that does not change the value tells
/// nobody.
///
/// **Its hooks** run on motion.library's task, holding the clock's
/// semaphore: quick, and waiting for nothing another task may hold while
/// it starts or stops an animation. **Its signal** goes to its owner,
/// which reads the newest value in its own time; steps it was too slow for
/// do not pile up.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The animation is the caller's until `DeleteAnimation`. Hooks named in
/// the tags must stay valid for as long as it does.
///
/// NOTES:
/// One clock serves every animation: steps of several animations due
/// together run on one wake of the clock.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartAnimation`, `StopAnimation`, `DeleteAnimation`,
/// `SetAnimationAttrsTagList`, `GetAnimationAttr`, `Ease`
///
/// EXAMPLES:
/// ```zig
/// // A level from 20 to 80 in a third of a second, slowing to its end;
/// // the program hears of each step by a signal.
/// const bit = sys.AllocSignal(-1);
/// const fill = mb.CreateAnimationTagList(&[_]TagItem{
///     .{ .tag = motion.ANIM_From, .data = 20 },
///     .{ .tag = motion.ANIM_To, .data = 80 },
///     .{ .tag = motion.ANIM_Duration, .data = 330 },
///     .{ .tag = motion.ANIM_Easing, .data = motion.EASE_OUT },
///     .{ .tag = motion.ANIM_Signal, .data = @intCast(bit) },
///     .{},
/// }) orelse return;
/// defer mb.DeleteAnimation(fill);
/// mb.StartAnimation(fill);
/// ```
pub fn CreateAnimationTagList(mb: *MotionBase, tags: ?[*]const TagItem) ?*motion.Animation {
    const sys = mb.sys_base;
    const memory = sys.AllocVec(@sizeOf(_anim.Anim), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const anim: *_anim.Anim = @ptrCast(@alignCast(memory));
    anim.* = .{};
    _ = _anim.setTags(mb, anim, tags);
    anim.value = anim.from;
    if (!_clock.adopt(mb, &anim.clocked, null)) {
        sys.FreeVec(memory);
        return null;
    }
    return @ptrCast(anim);
}
