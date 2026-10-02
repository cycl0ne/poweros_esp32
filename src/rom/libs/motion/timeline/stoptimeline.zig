// SPDX-License-Identifier: MPL-2.0
//! StopTimeline: every animation of a timeline stopped.

const sdk = @import("sdk");
const motion = sdk.motion;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _timeline = @import("_timeline.zig");

/// Every animation of a timeline stopped.
///
/// SYNOPSIS:
/// ```zig
/// fn StopTimeline(mb: *MotionBase, timeline: *Timeline, where: u32) void
/// ```
///
/// SINCE: 1.4. LVO -92.
///
/// INPUTS:
/// - `timeline` - one from `CreateTimelineTagList`.
/// - `where` - `STOP_WHERE_IT_IS` or `STOP_AT_END`, for each animation as
///   `StopAnimation` takes it.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Each running animation is stopped and told as when it ends; the last of
/// them tells the timeline's done hook and signal. Nothing for a timeline
/// none of whose animations runs.
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
/// `STOP_AT_END` puts each animation at its own end, forwards: for a
/// reversed timeline that is the end it was going away from.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartTimeline`, `StopAnimation`
///
/// EXAMPLES:
/// ```zig
/// mb.StopTimeline(line, motion.STOP_AT_END);
/// ```
pub fn StopTimeline(mb: *MotionBase, timeline: *motion.Timeline, where: u32) void {
    _timeline.stop(mb, _timeline.of(timeline), where);
}
