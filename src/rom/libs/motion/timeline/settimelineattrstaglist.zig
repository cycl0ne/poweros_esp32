// SPDX-License-Identifier: MPL-2.0
//! SetTimelineAttrsTagList: a timeline's tags changed.

const sdk = @import("sdk");
const motion = sdk.motion;
const TagItem = sdk.utility.TagItem;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _timeline = @import("_timeline.zig");

/// A timeline's tags changed.
///
/// SYNOPSIS:
/// ```zig
/// fn SetTimelineAttrsTagList(mb: *MotionBase, timeline: *Timeline,
///     tags: ?[*]const TagItem) u32
/// ```
///
/// SINCE: 1.4. LVO -100.
///
/// INPUTS:
/// - `timeline` - one from `CreateTimelineTagList`.
/// - `tags` - any of the tags it was made with.
///
/// RESULT:
/// How many of the tags it took.
///
/// BEHAVIOR:
/// They take effect from its next start: a reversed timeline set to play
/// forwards while it runs goes on backwards until it ends.
///
/// CONTEXT:
/// - Waits: for the clock's semaphore, while a step runs.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// A hook named stays the caller's, and must stay valid while the
/// timeline does.
///
/// NOTES:
/// What turns a timeline round between an opening and a closing.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateTimelineTagList`, `StartTimeline`
///
/// EXAMPLES:
/// ```zig
/// _ = mb.SetTimelineAttrsTagList(line, &[_]TagItem{
///     .{ .tag = motion.TIMELINE_Reverse, .data = 1 },
///     .{},
/// });
/// mb.StartTimeline(line);
/// ```
pub fn SetTimelineAttrsTagList(mb: *MotionBase, timeline: *motion.Timeline, tags: ?[*]const TagItem) u32 {
    const sys = mb.sys_base;
    const line = _timeline.of(timeline);
    sys.ObtainSemaphore(&mb.lock);
    defer sys.ReleaseSemaphore(&mb.lock);
    // A running reversed timeline keeps its direction until it ends: its
    // animations read it at every step.
    const reverse = line.reverse;
    const taken = _timeline.setTags(mb, line, tags);
    if (line.running != 0) line.reverse = reverse;
    return taken;
}
