// SPDX-License-Identifier: MIT
//! CmdEndRenderPass: a render pass ended.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _command = @import("_command.zig");

/// Recorded: the render pass ended, and what it drew stored.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdEndRenderPass(base: *FacetBase, buffer: *facet.CommandBuffer) void
/// ```
///
/// SINCE: 1.0. LVO -280.
///
/// INPUTS:
/// - `buffer` - a command buffer recording, inside a render pass.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Played, the tiles the draws touched are drawn - shared out between the
/// cores - and stored into the colour attachment; with a CLEAR load op the
/// whole render area is.
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
/// This is where the work of a frame is done: the draws only gather it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdBeginRenderPass`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdEndRenderPass(commands);
/// ```
pub fn CmdEndRenderPass(base: *FacetBase, buffer: *facet.CommandBuffer) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    _command.record(made, _command.EndRenderPass{}, u8, &.{});
}
