// SPDX-License-Identifier: MIT
//! CmdSetStencilWriteMask: the stencil test's write mask set.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _command = @import("_command.zig");

/// Recorded: the stencil test's write mask, for a pipeline that leaves it to commands.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdSetStencilWriteMask(base: *FacetBase, buffer: *facet.CommandBuffer, face_mask: u32, value: u32) void
/// ```
///
/// SINCE: 1.15. LVO -380.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `face_mask` - the faces it is for: STENCIL_FACE_FRONT, STENCIL_FACE_BACK
///   or STENCIL_FACE_FRONT_AND_BACK.
/// - `value` - its low 8 bits.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The draws after it with a pipeline that leaves this to commands test
/// their stencil by it.
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
/// fb.CmdSetStencilWriteMask(commands, facet.STENCIL_FACE_FRONT_AND_BACK, 1);
/// ```
pub fn CmdSetStencilWriteMask(base: *FacetBase, buffer: *facet.CommandBuffer, face_mask: u32, value: u32) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    _command.record(made, _command.SetStencil{ .which = .write, .face_mask = face_mask, .value = @truncate(value) }, u8, &.{});
}
