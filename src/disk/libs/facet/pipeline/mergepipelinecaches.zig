// SPDX-License-Identifier: MIT
//! MergePipelineCaches: what pipeline caches hold put into another.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;

/// What `sources` hold put into `destination`: nothing, none holding any.
///
/// SYNOPSIS:
/// ```zig
/// fn MergePipelineCaches(base: *FacetBase, device: *facet.Device, destination: *facet.PipelineCache, count: u32, sources: [*]const *facet.PipelineCache) facet.Result
/// ```
///
/// SINCE: 1.130. LVO -592.
///
/// INPUTS:
/// - `device` - the device they were made on.
/// - `destination` - the cache put into, not among the sources.
/// - `count`, `sources` - the caches put into it.
///
/// RESULT:
/// `success`.
///
/// BEHAVIOR:
/// A cache holds nothing, so nothing is put anywhere, as lavapipe has it
/// (`lvp_MergePipelineCaches`, lvp_pipeline_cache.c:96-103).
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caches stay the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreatePipelineCache`, `GetPipelineCacheData`
///
/// EXAMPLES:
/// ```zig
/// _ = fb.MergePipelineCaches(device, kept.?, 1, @ptrCast(&worker));
/// ```
pub fn MergePipelineCaches(base: *FacetBase, device: *facet.Device, destination: *facet.PipelineCache, count: u32, sources: [*]const *facet.PipelineCache) facet.Result {
    _ = base;
    _ = device;
    _ = destination;
    _ = count;
    _ = sources;
    return .success;
}
