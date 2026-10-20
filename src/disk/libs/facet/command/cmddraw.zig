// SPDX-License-Identifier: MIT
//! CmdDraw: vertices drawn.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _command = @import("_command.zig");

/// Recorded: vertices drawn, in the order they are in the vertex buffers.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdDraw(base: *FacetBase, buffer: *facet.CommandBuffer, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void
/// ```
///
/// SINCE: 1.0. LVO -312.
///
/// INPUTS:
/// - `buffer` - a command buffer recording, inside a render pass.
/// - `vertex_count` - how many vertices.
/// - `instance_count` - how many times they are drawn.
/// - `first_vertex` - the first: the vertices are it and those after it.
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
/// The vertex function is given each vertex's number and the instance's,
/// as Vulkan's vertex and instance indices.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdDrawIndexed`, `CmdBindPipeline`, `CmdBindVertexBuffers`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdDraw(commands, 36, 1, 0, 0);
/// ```
pub fn CmdDraw(base: *FacetBase, buffer: *facet.CommandBuffer, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    _command.record(made, _command.Draw{ .vertex_count = vertex_count, .instance_count = instance_count, .first_vertex = first_vertex, .first_instance = first_instance }, u8, &.{});
}
