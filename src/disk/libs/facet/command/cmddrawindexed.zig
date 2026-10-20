// SPDX-License-Identifier: MIT
//! CmdDrawIndexed: vertices drawn by their indices.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _command = @import("_command.zig");

/// Recorded: vertices drawn in the order the index buffer gives them.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdDrawIndexed(base: *FacetBase, buffer: *facet.CommandBuffer, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32, first_instance: u32) void
/// ```
///
/// SINCE: 1.0. LVO -316.
///
/// INPUTS:
/// - `buffer` - a command buffer recording, inside a render pass.
/// - `index_count` - how many indices.
/// - `instance_count` - how many times they are drawn.
/// - `first_index` - the first index read from the index buffer.
/// - `vertex_offset` - added to each index for its vertex.
/// - `first_instance` - the first instance's number.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Played inside a render pass, the vertices the draw names - from the
/// lowest to the highest - are read from the vertex buffers and given to
/// the pipeline's vertex function, in one batch for each instance; the
/// triangles are put together from them as the pipeline's topology says,
/// clipped, culled and set up, and gathered on the tiles they touch. The
/// fragment function colours them as the pass ends. A draw outside a render
/// pass, or without a pipeline bound, draws nothing.
///
/// An index past the index buffer's end, or naming a vertex below 0, leaves
/// its triangle out.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// None.
///
/// NOTES:
/// A shared vertex is worked once for each instance however many triangles
/// name it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdDraw`, `CmdBindIndexBuffer`, `CmdBindPipeline`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdDrawIndexed(commands, 36, 1, 0, 0, 0);
/// ```
pub fn CmdDrawIndexed(base: *FacetBase, buffer: *facet.CommandBuffer, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32, first_instance: u32) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    _command.record(made, _command.DrawIndexed{ .index_count = index_count, .instance_count = instance_count, .first_index = first_index, .vertex_offset = vertex_offset, .first_instance = first_instance }, u8, &.{});
}
