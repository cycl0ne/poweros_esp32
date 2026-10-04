// SPDX-License-Identifier: MPL-2.0
//! SetTimelineProgress: every animation of a timeline put at a point of it.

const sdk = @import("sdk");
const motion = sdk.motion;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _timeline = @import("_timeline.zig");

/// Every animation of a timeline put where it is at a point of the
/// timeline: scrubbing.
///
/// SYNOPSIS:
/// ```zig
/// fn SetTimelineProgress(mb: *MotionBase, timeline: *Timeline, at: u32) void
/// ```
///
/// SINCE: 1.4. LVO -96.
///
/// INPUTS:
/// - `timeline` - one from `CreateTimelineTagList`.
/// - `at` - milliseconds from the timeline's start, forwards; past its
///   end is its end.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Each animation stops and takes the value it has at that point - its
/// start before its offset, its end after its last play - and its step
/// hook and signal are told when the value moved. The timeline is left
/// stopped, its done hook untold; started again it runs from its start.
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
/// What a slider dragged along a timeline calls with the slider's value:
/// everything moves to where it would be then, at the drag's own speed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartTimeline`, `StopTimeline`
///
/// EXAMPLES:
/// ```zig
/// mb.SetTimelineProgress(line, 150);
/// ```
pub fn SetTimelineProgress(mb: *MotionBase, timeline: *motion.Timeline, at: u32) void {
    _timeline.setProgress(mb, _timeline.of(timeline), at);
}
