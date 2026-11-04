// SPDX-License-Identifier: MIT
//! CmdSetBlendConstantsAt: one colour attachment's blend constants set.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _command = @import("_command.zig");

/// Recorded: one colour attachment's own blend constants, for a pipeline that leaves them to commands.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdSetBlendConstantsAt(base: *FacetBase, buffer: *facet.CommandBuffer, attachment: u32, constants: *const [4]f32) void
/// ```
///
/// SINCE: 1.51. LVO -520.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `attachment` - which colour attachment of the subpass, 0 to 3.
/// - `constants` - red, green, blue and alpha, 0 to 1.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The draws after it with a pipeline whose blend constants are dynamic mix
/// that one colour attachment by these, and the others by whatever they had:
/// what CmdSetBlendConstants set over all of them, or their own set before.
/// facet.library's own, where Vulkan has the one set a pipeline shares
/// between its attachments - which matters where a subpass draws several
/// together and one fragment call writes them all
/// (SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER), there being no replay left to
/// set them between.
///
/// A later CmdSetBlendConstants sets the one set again over every
/// attachment, and forgets what this set for any of them. An `attachment`
/// past the subpass's does nothing.
///
/// The pipeline's own constants win where it has them
/// (`PipelineColorBlendStateCreateInfo.attachment_constants`,
/// `blend_constants`): a command sets only what a pipeline left to one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The constants are copied as the command is recorded.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdSetBlendConstants`, `CreateGraphicsPipelines`, `CreateRenderPass`
///
/// EXAMPLES:
/// ```zig
/// // The second attachment of a G-buffer mixed by a constant of its own.
/// fb.CmdSetBlendConstantsAt(commands, 1, &.{ 0.25, 0.25, 0.25, 1 });
/// ```
pub fn CmdSetBlendConstantsAt(base: *FacetBase, buffer: *facet.CommandBuffer, attachment: u32, constants: *const [4]f32) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    _command.record(made, _command.SetBlendConstantsAt{ .attachment = attachment, .constants = constants.* }, u8, &.{});
}
