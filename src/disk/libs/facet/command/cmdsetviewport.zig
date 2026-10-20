// SPDX-License-Identifier: MIT
//! CmdSetViewport: the viewport set.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _command = @import("_command.zig");

/// Recorded: the viewport, for a pipeline that leaves it to commands.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdSetViewport(base: *FacetBase, buffer: *facet.CommandBuffer, first_viewport: u32, count: u32, viewports: [*]const facet.Viewport) void
/// ```
///
/// SINCE: 1.0. LVO -304.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `first_viewport`, `count`, `viewports` - viewport 0, the one there is,
///   and any after it, which are not looked at.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The draws after it with a pipeline whose viewport is dynamic draw
/// through it; a pipeline with a viewport of its own draws through that.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The viewport is copied as the command is recorded.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdSetScissor`, `CreateGraphicsPipelines`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdSetViewport(commands, 0, 1, @ptrCast(&facet.Viewport{ .width = 800, .height = 600 }));
/// ```
pub fn CmdSetViewport(base: *FacetBase, buffer: *facet.CommandBuffer, first_viewport: u32, count: u32, viewports: [*]const facet.Viewport) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    if (first_viewport != 0 or count == 0) return;
    _command.record(made, _command.SetViewport{ .viewport = viewports[0] }, u8, &.{});
}
