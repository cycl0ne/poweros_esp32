// SPDX-License-Identifier: MIT
//! CmdSetScissor: the scissor set.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _command = @import("_command.zig");

/// Recorded: the scissor, for a pipeline that leaves it to commands.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdSetScissor(base: *FacetBase, buffer: *facet.CommandBuffer, first_scissor: u32, count: u32, scissors: [*]const facet.Rect2D) void
/// ```
///
/// SINCE: 1.0. LVO -308.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `first_scissor`, `count`, `scissors` - scissor 0, the one there is,
///   and any after it, which are not looked at.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The draws after it with a pipeline whose scissor is dynamic draw only
/// inside it, and inside the render area.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The scissor is copied as the command is recorded.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdSetViewport`, `CreateGraphicsPipelines`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdSetScissor(commands, 0, 1, @ptrCast(&facet.Rect2D{ .extent = .{ .width = 800, .height = 600 } }));
/// ```
pub fn CmdSetScissor(base: *FacetBase, buffer: *facet.CommandBuffer, first_scissor: u32, count: u32, scissors: [*]const facet.Rect2D) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    if (first_scissor != 0 or count == 0) return;
    _command.record(made, _command.SetScissor{ .scissor = scissors[0] }, u8, &.{});
}
