// SPDX-License-Identifier: MPL-2.0
//! AddTimelineAnimation: an animation into a timeline, at an offset.

const sdk = @import("sdk");
const motion = sdk.motion;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _anim = @import("../anim/_anim.zig");
const _timeline = @import("_timeline.zig");

/// An animation into a timeline, beginning some time after it.
///
/// SYNOPSIS:
/// ```zig
/// fn AddTimelineAnimation(mb: *MotionBase, timeline: *Timeline,
///     animation: *Animation, offset: u32) bool
/// ```
///
/// SINCE: 1.4. LVO -84.
///
/// INPUTS:
/// - `timeline` - one from `CreateTimelineTagList`.
/// - `animation` - one from `CreateAnimationTagList`, in no timeline.
/// - `offset` - milliseconds from the timeline's start to this
///   animation's; its own `ANIM_Delay` comes after that.
///
/// RESULT:
/// True when it is in; false for one that plays for ever (a timeline has
/// to end) or is in a timeline already.
///
/// BEHAVIOR:
/// From now on the timeline starts and stops it. Started on its own with
/// `StartAnimation`, it leaves the timeline.
///
/// CONTEXT:
/// - Waits: for the clock's semaphore, while a step runs.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The animation stays the caller's; deleting it takes it out of the
/// timeline.
///
/// NOTES:
/// The timeline's length is worked out when it starts, so an animation's
/// duration may still be changed after it is added.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateTimelineTagList`, `StartTimeline`
///
/// EXAMPLES:
/// ```zig
/// _ = mb.AddTimelineAnimation(line, fade, 100);
/// ```
pub fn AddTimelineAnimation(mb: *MotionBase, timeline: *motion.Timeline, animation: *motion.Animation, offset: u32) bool {
    const sys = mb.sys_base;
    sys.ObtainSemaphore(&mb.lock);
    defer sys.ReleaseSemaphore(&mb.lock);
    return _timeline.add(mb, _timeline.of(timeline), _anim.of(animation), offset);
}
