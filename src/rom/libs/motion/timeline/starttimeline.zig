// SPDX-License-Identifier: MPL-2.0
//! StartTimeline: every animation of a timeline run from its start.

const sdk = @import("sdk");
const motion = sdk.motion;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _timeline = @import("_timeline.zig");

/// A timeline run from its start, or from its end reversed.
///
/// SYNOPSIS:
/// ```zig
/// fn StartTimeline(mb: *MotionBase, timeline: *Timeline) void
/// ```
///
/// SINCE: 1.4. LVO -88.
///
/// INPUTS:
/// - `timeline` - one from `CreateTimelineTagList`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Its time starts now, and each animation's at its offset from that.
/// **Reversed** (`TIMELINE_Reverse`) every animation begins at its end
/// and goes back to its start, the last to begin forwards the first to
/// go back. When the last of its animations ends, its done hook and
/// signal follow theirs. One that runs already starts again.
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
/// A panel that slid in slides out with the same timeline reversed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StopTimeline`, `SetTimelineProgress`, `SetTimelineAttrsTagList`
///
/// EXAMPLES:
/// ```zig
/// mb.StartTimeline(line);
/// ```
pub fn StartTimeline(mb: *MotionBase, timeline: *motion.Timeline) void {
    _timeline.start(mb, _timeline.of(timeline));
}
