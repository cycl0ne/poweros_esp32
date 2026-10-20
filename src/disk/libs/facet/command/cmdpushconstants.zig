// SPDX-License-Identifier: MIT
//! CmdPushConstants: push constants set.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const shader = facet.shader;
const _command = @import("_command.zig");

/// Recorded: bytes of push constants set.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdPushConstants(base: *FacetBase, buffer: *facet.CommandBuffer, layout: *facet.PipelineLayout, stage_flags: u32, offset: u32, size: u32, values: *const anyopaque) void
/// ```
///
/// SINCE: 1.0. LVO -300.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `layout` - the pipeline layout they are set for.
/// - `stage_flags` - the stages that read them.
/// - `offset`, `size` - which bytes, inside the first 128.
/// - `values` - `size` bytes.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The draws after it read the push constants as `Resources.push`, every
/// stage the same bytes. Bytes not set are 0 as each command buffer
/// starts. A range past byte 128 is not recorded.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bytes are copied as the command is recorded.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreatePipelineLayout`, `CmdDraw`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdPushConstants(commands, layout.?, facet.SHADER_STAGE_VERTEX, 0, @sizeOf(Matrix), &transform);
/// ```
pub fn CmdPushConstants(base: *FacetBase, buffer: *facet.CommandBuffer, layout: *facet.PipelineLayout, stage_flags: u32, offset: u32, size: u32, values: *const anyopaque) void {
    _ = base;
    _ = layout;
    _ = stage_flags;
    const made = _command.recording(buffer) orelse return;
    if (offset > shader.MAX_PUSH_CONSTANTS_SIZE or size > shader.MAX_PUSH_CONSTANTS_SIZE - offset) return;
    const bytes: [*]const u8 = @ptrCast(values);
    _command.record(made, _command.PushConstants{ .offset = offset, .size = size }, u8, bytes[0..size]);
}
