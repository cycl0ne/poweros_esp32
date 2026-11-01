// SPDX-License-Identifier: MIT
//! CmdSetLineWidth: the width of lines set.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _command = @import("_command.zig");

/// Recorded: the width of lines, for a pipeline that leaves it to commands.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdSetLineWidth(base: *FacetBase, buffer: *facet.CommandBuffer, width: f32) void
/// ```
///
/// SINCE: 1.14. LVO -372.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `width` - in pixels.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The draws after it with a pipeline whose line width is dynamic draw their
/// lines this wide.
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
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateGraphicsPipelines`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdSetLineWidth(commands, 2);
/// ```
pub fn CmdSetLineWidth(base: *FacetBase, buffer: *facet.CommandBuffer, width: f32) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    _command.record(made, _command.SetLineWidth{ .width = width }, u8, &.{});
}
