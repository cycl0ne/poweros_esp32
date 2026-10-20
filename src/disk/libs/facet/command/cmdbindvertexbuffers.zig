// SPDX-License-Identifier: MIT
//! CmdBindVertexBuffers: the vertex buffers draws read.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Buffer = @import("../buffer/_buffer.zig").Buffer;
const max_vertex_input_bindings = @import("../instance/_instance.zig").max_vertex_input_bindings;

/// Recorded: vertex buffers bound, from binding `first_binding` on.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdBindVertexBuffers(base: *FacetBase, buffer: *facet.CommandBuffer, first_binding: u32, count: u32, buffers: [*]const *facet.Buffer, offsets: [*]const u64) void
/// ```
///
/// SINCE: 1.0. LVO -288.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `first_binding` - the first binding bound.
/// - `count`, `buffers`, `offsets` - a buffer for each binding from it, and
///   where its vertices start in it.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A draw reads each attribute from its binding's buffer: a vertex's from
/// its offset, plus the binding's stride times the vertex, plus the
/// attribute's own offset. A value past the buffer's end is (0, 0, 0, 1).
/// Bindings past the fourth are not bound.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The arrays are copied as the command is recorded. The buffers have to
/// last until the work is done.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdDraw`, `CmdBindIndexBuffer`
///
/// EXAMPLES:
/// ```zig
/// const offset: u64 = 0;
/// fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertices), @ptrCast(&offset));
/// ```
pub fn CmdBindVertexBuffers(base: *FacetBase, buffer: *facet.CommandBuffer, first_binding: u32, count: u32, buffers: [*]const *facet.Buffer, offsets: [*]const u64) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    if (first_binding >= max_vertex_input_bindings) return;
    var bound: [max_vertex_input_bindings]_command.VertexBuffer = undefined;
    const taken = @min(count, max_vertex_input_bindings - first_binding);
    for (bound[0..taken], buffers[0..taken], offsets[0..taken]) |*into, given, offset| into.* = .{ .buffer = _objects.of(Buffer, given), .offset = offset };
    _command.record(made, _command.BindVertexBuffers{ .first = first_binding, .count = taken }, _command.VertexBuffer, bound[0..taken]);
}
