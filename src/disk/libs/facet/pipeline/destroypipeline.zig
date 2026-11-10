// SPDX-License-Identifier: MIT
//! DestroyPipeline: a pipeline given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Pipeline = @import("_pipeline.zig").Pipeline;

/// The pipeline given back: no submission still drawing with it.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroyPipeline(base: *FacetBase, device: *facet.Device, pipeline: ?*facet.Pipeline) void
/// ```
///
/// SINCE: 1.0. LVO -272.
///
/// INPUTS:
/// - `device` - the device.
/// - `pipeline` - a pipeline CreateGraphicsPipelines made, or null, which
///   does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// No command buffer still pending may have bound it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pipeline is gone.
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
/// fb.DestroyPipeline(device, pipeline);
/// ```
pub fn DestroyPipeline(base: *FacetBase, device: *facet.Device, pipeline: ?*facet.Pipeline) void {
    _ = device;
    const made = _objects.of(Pipeline, pipeline orelse return);
    made.device.physical.ops.unmake_pipeline(made);
    _objects.destroy(base.sys_base, made);
}
