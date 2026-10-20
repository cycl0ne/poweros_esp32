// SPDX-License-Identifier: MIT
//! CmdBindIndexBuffer: the index buffer indexed draws read.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Buffer = @import("../buffer/_buffer.zig").Buffer;

/// Recorded: the index buffer CmdDrawIndexed reads.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdBindIndexBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, index_buffer: *facet.Buffer, offset: u64, index_type: facet.IndexType) void
/// ```
///
/// SINCE: 1.0. LVO -292.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `index_buffer` - the buffer.
/// - `offset` - where the indices start in it.
/// - `index_type` - `uint16` or `uint32`.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// An indexed draw reads its indices from here; one past the buffer's end
/// names no vertex, and leaves its triangle out.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffer has to last until the work is done.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdDrawIndexed`, `CmdBindVertexBuffers`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdBindIndexBuffer(commands, indices.?, 0, .uint16);
/// ```
pub fn CmdBindIndexBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, index_buffer: *facet.Buffer, offset: u64, index_type: facet.IndexType) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    if (index_type != .uint16 and index_type != .uint32) return;
    _command.record(made, _command.BindIndexBuffer{ .buffer = _objects.of(Buffer, index_buffer), .offset = offset, .index_type = index_type }, u8, &.{});
}
