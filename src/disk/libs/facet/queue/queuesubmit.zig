// SPDX-License-Identifier: MIT
//! QueueSubmit: work for a queue.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _queue = @import("_queue.zig");
const Fence = @import("../sync/_sync.zig").Fence;

/// Batches of work for the queue, played in order by its task.
///
/// SYNOPSIS:
/// ```zig
/// fn QueueSubmit(base: *FacetBase, queue: *facet.Queue, count: u32, submits: ?[*]const facet.SubmitInfo, fence: ?*facet.Fence) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -164.
///
/// INPUTS:
/// - `queue` - the queue.
/// - `count`, `submits` - the batches: for each, the semaphores it waits
///   for, the command buffers it plays and the semaphores it signals.
/// - `fence` - signalled when all of them are done; may be null. With no
///   batches, signalled when all submitted before is done.
///
/// RESULT:
/// `success`; `error_out_of_host_memory`, and nothing submitted.
///
/// BEHAVIOR:
/// The queue's task takes the batches in the order they were submitted,
/// after everything submitted before: for each it waits until each of its
/// semaphores is signalled, and takes the signal; plays its command
/// buffers, one after the other, each command finished before the next
/// starts; then signals its semaphores, and with the last batch the fence.
/// A command buffer not executable - not ended, or spent by a one-time
/// submission - is passed over.
///
/// The call returns at once: the work is the task's.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: the queue's list, for a moment.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The arrays are copied as the call is made. The command buffers, and
/// everything their commands name, have to last until the work is done:
/// until the fence is signalled.
///
/// NOTES:
/// A command buffer recorded with ONE_TIME_SUBMIT is spent once played;
/// any other may be submitted again once its work is done, or while it is
/// pending if it was recorded with SIMULTANEOUS_USE.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WaitForFences`, `QueueWaitIdle`, `CreateSemaphore`
///
/// EXAMPLES:
/// ```zig
/// const submit = facet.SubmitInfo{ .command_buffer_count = 1, .command_buffers = @ptrCast(&commands[0]) };
/// if (fb.QueueSubmit(queue.?, 1, @ptrCast(&submit), frame_done) != .success) return error.NoSubmit;
/// ```
pub fn QueueSubmit(base: *FacetBase, queue: *facet.Queue, count: u32, submits: ?[*]const facet.SubmitInfo, fence: ?*facet.Fence) facet.Result {
    const made = _objects.of(_queue.Queue, queue);
    const given: []const facet.SubmitInfo = if (submits) |infos| infos[0..count] else &.{};
    const done: ?*Fence = if (fence) |handle| _objects.of(Fence, handle) else null;
    return _queue.submit(made, base.sys_base, given, done, base.inline_queues);
}
