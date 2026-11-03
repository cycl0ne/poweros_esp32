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
/// A group holds as many invocations as the function's entry declared
/// (`shader.computeGroup`), which the call is given in
/// `shader.Groups.local`: the function makes them itself, so one call runs
/// them all, one after the other, in whatever order it chooses. What they
/// share is `shader.Groups.shared`, as many bytes as the entry asked for,
/// found once for each worker of the dispatch and given back as it ends: a
/// group has it to itself while it runs, cleared for the first group a worker
/// takes and holding what the group before it left after that. Memory the
/// library could not find leaves `shared` null.
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
/// `CreateComputePipelines`, `CmdDispatchIndirect`, `CmdBindDescriptorSets`,
/// `shader.computeGroup`
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
