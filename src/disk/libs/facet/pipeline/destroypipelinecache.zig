// SPDX-License-Identifier: MIT
//! DestroyPipelineCache: a pipeline cache given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Cache = @import("_pipeline.zig").Cache;

/// The pipeline cache given back.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroyPipelineCache(base: *FacetBase, device: *facet.Device, cache: ?*facet.PipelineCache) void
/// ```
///
/// SINCE: 1.130. LVO -584.
///
/// INPUTS:
/// - `device` - the device it was made on.
/// - `cache` - the cache, or null, which does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// As lavapipe gives its back (`lvp_DestroyPipelineCache`,
/// lvp_pipeline_cache.c:55-68). The pipelines made with it are not its,
/// and stay.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The cache is gone.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreatePipelineCache`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroyPipelineCache(device, cache);
/// ```
pub fn DestroyPipelineCache(base: *FacetBase, device: *facet.Device, cache: ?*facet.PipelineCache) void {
    _ = device;
    _objects.destroy(base.sys_base, _objects.of(Cache, cache orelse return));
}
