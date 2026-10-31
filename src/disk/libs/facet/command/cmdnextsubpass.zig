// SPDX-License-Identifier: MIT
//! CmdNextSubpass: a render pass's next subpass begun.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _command = @import("_command.zig");

/// Recorded: what the subpass drew stored, and the next subpass begun.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdNextSubpass(base: *FacetBase, buffer: *facet.CommandBuffer, contents: facet.SubpassContents) void
/// ```
///
/// SINCE: 1.21. LVO -428.
///
/// INPUTS:
/// - `buffer` - a command buffer recording, inside a render pass of a further
///   subpass.
/// - `contents` - whether the subpass's draws are in secondary command
///   buffers. Not looked at: either may be played.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A subpass with other attachments than the one before it is a pass of its
/// own: it stores what was drawn, and begins with the clear values
/// CmdBeginRenderPass was given. One with the same attachments goes on in the
/// same tiles, the depth with them, and only the pipelines it can bind differ.
///
/// Past the last subpass, or outside a pass, nothing is recorded. A pipeline
/// bound stays bound, though Vulkan would have one made for the subpass.
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
/// A subpass of several colour attachments is played over for each of them from where it began, with what was bound then.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdBeginRenderPass`, `CmdEndRenderPass`, `CreateRenderPass`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdNextSubpass(commands, .@"inline");
/// ```
pub fn CmdNextSubpass(base: *FacetBase, buffer: *facet.CommandBuffer, contents: facet.SubpassContents) void {
    _ = base;
    _ = contents;
    const made = _command.recording(buffer) orelse return;
    const pass = made.pass orelse return;
    if (made.subpass + 1 >= pass.subpass_count) return;
    made.subpass += 1;
    if (pass.subpasses[made.subpass].joined) return;
    _command.record(made, _command.EndRenderPass{}, u8, &.{});
    _command.beginSubpass(made, made.subpass);
}
