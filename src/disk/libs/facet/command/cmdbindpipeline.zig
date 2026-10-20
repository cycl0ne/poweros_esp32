// SPDX-License-Identifier: MIT
//! CmdBindPipeline: the pipeline draws draw with.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Pipeline = @import("../pipeline/_pipeline.zig").Pipeline;

/// Recorded: the pipeline the draws after it draw with.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdBindPipeline(base: *FacetBase, buffer: *facet.CommandBuffer, bind_point: facet.PipelineBindPoint, pipeline: *facet.Pipeline) void
/// ```
///
/// SINCE: 1.0. LVO -284.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `bind_point` - `graphics`; nothing is recorded for another.
/// - `pipeline` - a graphics pipeline.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The pipeline stays bound until another is, or the command buffer ends.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pipeline has to last until the work is done.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateGraphicsPipelines`, `CmdDraw`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdBindPipeline(commands, .graphics, pipeline.?);
/// ```
pub fn CmdBindPipeline(base: *FacetBase, buffer: *facet.CommandBuffer, bind_point: facet.PipelineBindPoint, pipeline: *facet.Pipeline) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    if (bind_point != .graphics) return;
    _command.record(made, _command.BindPipeline{ .pipeline = _objects.of(Pipeline, pipeline) }, u8, &.{});
}
