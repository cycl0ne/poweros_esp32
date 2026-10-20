// SPDX-License-Identifier: MIT
//! DestroyPipelineLayout: a pipeline layout given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const PipelineLayout = @import("_pipeline.zig").PipelineLayout;

/// The pipeline layout given back.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroyPipelineLayout(base: *FacetBase, device: *facet.Device, layout: ?*facet.PipelineLayout) void
/// ```
///
/// SINCE: 1.0. LVO -240.
///
/// INPUTS:
/// - `device` - the device.
/// - `layout` - a layout CreatePipelineLayout made, or null, which does
///   nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The pipelines made with it stay.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The layout is gone.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreatePipelineLayout`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroyPipelineLayout(device, layout);
/// ```
pub fn DestroyPipelineLayout(base: *FacetBase, device: *facet.Device, layout: ?*facet.PipelineLayout) void {
    _ = device;
    _objects.destroy(base.sys_base, _objects.of(PipelineLayout, layout orelse return));
}
