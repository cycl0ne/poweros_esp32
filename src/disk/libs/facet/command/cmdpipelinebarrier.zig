// SPDX-License-Identifier: MIT
//! CmdPipelineBarrier: the work before ordered before the work after.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _command = @import("_command.zig");

/// Recorded: a barrier between the work before it and the work after.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdPipelineBarrier(base: *FacetBase, buffer: *facet.CommandBuffer, src_stage_mask: u32, dst_stage_mask: u32, dependency_flags: u32, memory_barrier_count: u32, memory_barriers: ?[*]const facet.MemoryBarrier, buffer_barrier_count: u32, buffer_barriers: ?[*]const facet.BufferMemoryBarrier, image_barrier_count: u32, image_barriers: ?[*]const facet.ImageMemoryBarrier) void
/// ```
///
/// SINCE: 1.0. LVO -152.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `src_stage_mask`, `dst_stage_mask` - the stages before and after
///   (PIPELINE_STAGE_*).
/// - `dependency_flags` - 0.
/// - `memory_barrier_count`, `memory_barriers` - what memory is written
///   before and read after.
/// - `buffer_barrier_count`, `buffer_barriers` - the same for buffers.
/// - `image_barrier_count`, `image_barriers` - the same for images, and
///   the layouts they go from and to.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A queue plays its commands one after the other, each finished before
/// the next starts, and a layout changes nothing in memory: the barrier
/// is kept in its place in the recording, and has nothing to wait for
/// when it is played. A program written for any device records it all
/// the same.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The arrays are the caller's, read during the call.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdCopyBufferToImage`, `QueueSubmit`
///
/// EXAMPLES:
/// ```zig
/// const barrier = facet.ImageMemoryBarrier{
///     .dst_access_mask = facet.ACCESS_TRANSFER_WRITE,
///     .old_layout = .undefined,
///     .new_layout = .transfer_dst_optimal,
///     .image = picture.?,
/// };
/// fb.CmdPipelineBarrier(commands, facet.PIPELINE_STAGE_TOP_OF_PIPE, facet.PIPELINE_STAGE_TRANSFER, 0, 0, null, 0, null, 1, @ptrCast(&barrier));
/// ```
pub fn CmdPipelineBarrier(base: *FacetBase, buffer: *facet.CommandBuffer, src_stage_mask: u32, dst_stage_mask: u32, dependency_flags: u32, memory_barrier_count: u32, memory_barriers: ?[*]const facet.MemoryBarrier, buffer_barrier_count: u32, buffer_barriers: ?[*]const facet.BufferMemoryBarrier, image_barrier_count: u32, image_barriers: ?[*]const facet.ImageMemoryBarrier) void {
    _ = base;
    _ = dependency_flags;
    _ = memory_barrier_count;
    _ = memory_barriers;
    _ = buffer_barrier_count;
    _ = buffer_barriers;
    _ = image_barrier_count;
    _ = image_barriers;
    const made = _command.recording(buffer) orelse return;
    _command.record(made, _command.Barrier{ .src_stage_mask = src_stage_mask, .dst_stage_mask = dst_stage_mask }, u8, &.{});
}
