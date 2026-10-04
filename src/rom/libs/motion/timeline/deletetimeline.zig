// SPDX-License-Identifier: MPL-2.0
//! DeleteTimeline: a timeline let go of its animations and freed.

const sdk = @import("sdk");
const motion = sdk.motion;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _clock = @import("../clock/_clock.zig");
const _timeline = @import("_timeline.zig");

/// A timeline freed; its animations stay.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteTimeline(mb: *MotionBase, timeline: ?*Timeline) void
/// ```
///
/// SINCE: 1.4. LVO -80.
///
/// INPUTS:
/// - `timeline` - one from `CreateTimelineTagList`, or null.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Its animations are stopped where they are, untold, and let go of: they
/// are animations on their own again, the caller's to start or delete.
///
/// CONTEXT:
/// - Waits: for the clock's semaphore, while a step runs.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The timeline's memory goes back to the system; the animations stay the
/// caller's.
///
/// NOTES:
/// Delete the timeline before its animations, or delete them first: either
/// order is safe.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateTimelineTagList`, `DeleteAnimation`
///
/// EXAMPLES:
/// ```zig
/// mb.DeleteTimeline(line);
/// mb.DeleteAnimation(slide);
/// mb.DeleteAnimation(fade);
/// ```
pub fn DeleteTimeline(mb: *MotionBase, timeline: ?*motion.Timeline) void {
    const line = _timeline.of(timeline orelse return);
    _timeline.empty(mb, line);
    _clock.release(mb, &line.clocked);
    mb.sys_base.FreeVec(line);
}
