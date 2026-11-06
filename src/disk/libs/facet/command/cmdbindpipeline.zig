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
/// A pipeline and the command buffer it is recorded into have to come
/// from one device, as Vulkan requires. Nothing is recorded for a
/// pipeline from another: each device's driver reads `Pipeline.driver` as
/// its own kind of object, so drawing with another device's pipeline
/// would hand the hardware whatever lay at that field. (Since 1.79.)
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
    const bound = _objects.of(Pipeline, pipeline);
    // One device's pipeline is not another's. `Pipeline.driver` holds the
    // object the driver that compiled it made, and every driver casts
    // that field to its own kind without looking: a V3D draw would read
    // the cores' pipeline object as a shader record and hand what it
    // found there to the hardware as the address of a program. Vulkan
    // requires a pipeline and the command buffer it is recorded into to
    // come from one device, so this is a program's mistake, and nothing
    // is recorded for it.
    if (bound.device != made.device) return;
    switch (bind_point) {
        .graphics => if (bound.compute == null) _command.record(made, _command.BindPipeline{ .pipeline = bound }, u8, &.{}),
        .compute => if (bound.compute != null) _command.record(made, _command.BindComputePipeline{ .pipeline = bound }, u8, &.{}),
        _ => {},
    }
}
