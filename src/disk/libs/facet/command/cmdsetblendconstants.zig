// SPDX-License-Identifier: MIT
//! CmdSetBlendConstants: the blend constants set.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _command = @import("_command.zig");

/// Recorded: the blend constants, for a pipeline that leaves them to commands.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdSetBlendConstants(base: *FacetBase, buffer: *facet.CommandBuffer, constants: *const [4]f32) void
/// ```
///
/// SINCE: 1.12. LVO -368.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `constants` - red, green, blue and alpha, 0 to 1.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The draws after it with a pipeline whose blend constants are dynamic mix
/// by these.
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
/// `CreateGraphicsPipelines`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdSetBlendConstants(commands, &.{ 1, 0.5, 0.25, 1 });
/// ```
pub fn CmdSetBlendConstants(base: *FacetBase, buffer: *facet.CommandBuffer, constants: *const [4]f32) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    _command.record(made, _command.SetBlendConstants{ .constants = constants.* }, u8, &.{});
}
