// SPDX-License-Identifier: MPL-2.0
//! CreateTimelineTagList: a timeline, from its tags.

const sdk = @import("sdk");
const exec = sdk.exec;
const motion = sdk.motion;
const TagItem = sdk.utility.TagItem;
const MotionBase = @import("../motion_base.zig").MotionBase;
const _clock = @import("../clock/_clock.zig");
const _timeline = @import("_timeline.zig");

/// A timeline: animations started, stopped, reversed and scrubbed as one.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateTimelineTagList(mb: *MotionBase, tags: ?[*]const TagItem) ?*Timeline
/// ```
///
/// SINCE: 1.4. LVO -76.
///
/// INPUTS:
/// - `tags` - or null:
///   - `TIMELINE_Reverse` - it plays backwards (false).
///   - `TIMELINE_DoneHook`, `TIMELINE_Signal`, `TIMELINE_UserData` - how
///     its owner hears that the last of its animations has ended.
///
/// RESULT:
/// The timeline, empty and not running; null without the memory.
///
/// BEHAVIOR:
/// Animations go into it with `AddTimelineAnimation`, each at an offset
/// from its start. It runs no steps of its own: started, it gives each
/// animation one time to count from, so they keep together however late
/// their steps come. It belongs to the calling task, and goes with it.
///
/// CONTEXT:
/// - Waits: for the clock's semaphore, while a step runs, to put it in the
///   calling task's keeping.
/// - Interrupts: no.
/// - Locks: takes the clock's semaphore; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The timeline is the caller's until `DeleteTimeline`; the animations in
/// it stay the caller's too, and are deleted on their own.
///
/// NOTES:
/// A box that moves and fades, a panel sliding in while its contents
/// follow a little after: animations of their own, one timeline.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddTimelineAnimation`, `StartTimeline`, `StopTimeline`,
/// `SetTimelineProgress`, `DeleteTimeline`
///
/// EXAMPLES:
/// ```zig
/// const line = mb.CreateTimelineTagList(null) orelse return;
/// _ = mb.AddTimelineAnimation(line, slide, 0);
/// _ = mb.AddTimelineAnimation(line, fade, 100);
/// mb.StartTimeline(line);
/// ```
pub fn CreateTimelineTagList(mb: *MotionBase, tags: ?[*]const TagItem) ?*motion.Timeline {
    const sys = mb.sys_base;
    const memory = sys.AllocVec(@sizeOf(_timeline.Line), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const line: *_timeline.Line = @ptrCast(@alignCast(memory));
    line.* = .{};
    line.members.init();
    _ = _timeline.setTags(mb, line, tags);
    if (!_clock.adopt(mb, &line.clocked, null)) {
        sys.FreeVec(memory);
        return null;
    }
    return @ptrCast(line);
}
