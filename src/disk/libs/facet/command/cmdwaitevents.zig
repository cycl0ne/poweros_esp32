// SPDX-License-Identifier: MIT
//! CmdWaitEvents: the work after it held until events are set.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _command = @import("_command.zig");
const Event = @import("../sync/_sync.zig").Event;

/// Recorded: the work after it waits until each of the events is set.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdWaitEvents(base: *FacetBase, buffer: *facet.CommandBuffer, event_count: u32, events: [*]const *facet.Event, src_stage_mask: u32, dst_stage_mask: u32, memory_barrier_count: u32, memory_barriers: ?[*]const facet.MemoryBarrier, buffer_barrier_count: u32, buffer_barriers: ?[*]const facet.BufferMemoryBarrier, image_barrier_count: u32, image_barriers: ?[*]const facet.ImageMemoryBarrier) void
/// ```
///
/// SINCE: 1.129. LVO -576.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `event_count`, `events` - the events, one at least.
/// - `src_stage_mask` - the stages of the CmdSetEvents that set them,
///   and PIPELINE_STAGE_HOST for those the host sets (PIPELINE_STAGE_*).
/// - `dst_stage_mask` - the stages of the work after it that waits.
/// - `memory_barrier_count`, `memory_barriers`,
///   `buffer_barrier_count`, `buffer_barriers`, `image_barrier_count`,
///   `image_barriers` - what memory is written before and read after, as
///   for CmdPipelineBarrier.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Played, it has the queue's task wait until every one of the events is
/// set, as lavapipe's queue does (`handle_wait_events2`,
/// lvp_execute.c:3424-3433), leaving each set; then the commands after it
/// go on. Where lavapipe spins, the task sleeps until a SetEvent wakes it.
/// An event set by a CmdSetEvent earlier in the queue's order, or by the
/// host before the work was submitted, as Vulkan has it, is set already:
/// nothing is waited for. The barriers are what CmdPipelineBarrier's are
/// and change nothing, the queue doing each command before the next, so
/// the command is the wait alone; Mesa's runtime makes it the wait and
/// that barrier (`vk_common_CmdWaitEvents`, vk_synchronization.c:307-370).
/// No event at all records nothing, as there.
///
/// CONTEXT:
/// - Waits: no; the queue's task waits when it is played.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The arrays are the caller's, read during the call. The events are the
/// caller's, and have to last until the work is done.
///
/// NOTES:
/// An event the host sets after the work is submitted still lets the
/// queue go on when it is set: Vulkan 1.0 had a program wait so, and has
/// it set first since (its queue forward progress section). Until it is
/// set nothing after it on the queue is done, and an event nothing sets
/// holds the queue for ever.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdSetEvent`, `SetEvent`, `CmdPipelineBarrier`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdWaitEvents(commands, 1, @ptrCast(&uploaded), facet.PIPELINE_STAGE_TRANSFER, facet.PIPELINE_STAGE_VERTEX_INPUT, 0, null, 0, null, 0, null);
/// ```
pub fn CmdWaitEvents(base: *FacetBase, buffer: *facet.CommandBuffer, event_count: u32, events: [*]const *facet.Event, src_stage_mask: u32, dst_stage_mask: u32, memory_barrier_count: u32, memory_barriers: ?[*]const facet.MemoryBarrier, buffer_barrier_count: u32, buffer_barriers: ?[*]const facet.BufferMemoryBarrier, image_barrier_count: u32, image_barriers: ?[*]const facet.ImageMemoryBarrier) void {
    _ = base;
    _ = memory_barrier_count;
    _ = memory_barriers;
    _ = buffer_barrier_count;
    _ = buffer_barriers;
    _ = image_barrier_count;
    _ = image_barriers;
    const made = _command.recording(buffer) orelse return;
    if (event_count == 0) return;
    // A handle is its object's address (_objects.zig): the handles are
    // the events.
    const made_events: [*]const *Event = @ptrCast(events);
    _command.record(made, _command.WaitEvents{
        .count = event_count,
        .src_stage_mask = src_stage_mask,
        .dst_stage_mask = dst_stage_mask,
    }, *Event, made_events[0..event_count]);
}
