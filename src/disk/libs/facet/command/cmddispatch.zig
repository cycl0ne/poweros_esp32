// SPDX-License-Identifier: MIT
//! CmdDispatch: a compute function run.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _command = @import("_command.zig");

/// Recorded: the compute function bound run, for each of the groups.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdDispatch(base: *FacetBase, buffer: *facet.CommandBuffer, x: u32, y: u32, z: u32) void
/// ```
///
/// SINCE: 1.18. LVO -420.
///
/// INPUTS:
/// - `buffer` - a command buffer recording, outside a render pass.
/// - `x`, `y`, `z` - how many groups along each axis.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The function of the pipeline bound with `PipelineBindPoint.compute` is
/// called once for each group, given the descriptor sets bound for compute and
/// the push constants. What it writes is there for the commands after it. It
/// runs on the cores, the groups in no order and shared between them; the
/// dispatch ends when all are done. In a render pass it does nothing.
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
/// Barriers are taken and need do nothing: the cores run a command at a time.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateComputePipelines`, `CmdDispatchIndirect`, `CmdBindDescriptorSets`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdDispatch(commands, 16, 1, 1);
/// ```
pub fn CmdDispatch(base: *FacetBase, buffer: *facet.CommandBuffer, x: u32, y: u32, z: u32) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    _command.record(made, _command.Dispatch{ .count = .{ x, y, z } }, u8, &.{});
}
