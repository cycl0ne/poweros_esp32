// SPDX-License-Identifier: MIT
//! CreatePipelineCache: what pipelines are made faster with the next time.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const Cache = @import("_pipeline.zig").Cache;

/// A pipeline cache: what pipelines are made faster with the next time,
/// and what GetPipelineCacheData hands out to keep for another run.
///
/// SYNOPSIS:
/// ```zig
/// fn CreatePipelineCache(base: *FacetBase, device: *facet.Device, info: *const facet.PipelineCacheCreateInfo, cache: *?*facet.PipelineCache) facet.Result
/// ```
///
/// SINCE: 1.130. LVO -580.
///
/// INPUTS:
/// - `device` - the device.
/// - `info` - 0 for its flags, and what an earlier GetPipelineCacheData
///   gave, or none.
/// - `cache` - where the cache is written; null when it fails.
///
/// RESULT:
/// `success`; `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// The cache holds nothing, as lavapipe's holds nothing
/// (`lvp_CreatePipelineCache`, lvp_pipeline_cache.c:26-53), and the initial
/// data is not read: what GetPipelineCacheData gives is a header and no
/// pipeline, and data from anywhere else leaves a cache empty in Vulkan as
/// well.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The cache is the caller's, until DestroyPipelineCache. The initial
/// data stays the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DestroyPipelineCache`, `GetPipelineCacheData`, `CreateGraphicsPipelines`
///
/// EXAMPLES:
/// ```zig
/// var cache: ?*facet.PipelineCache = null;
/// if (fb.CreatePipelineCache(device, &.{}, &cache) != .success) return error.NoCache;
/// ```
pub fn CreatePipelineCache(base: *FacetBase, device: *facet.Device, info: *const facet.PipelineCacheCreateInfo, cache: *?*facet.PipelineCache) facet.Result {
    _ = info;
    cache.* = null;
    const made = _objects.create(base.sys_base, Cache) orelse return .error_out_of_host_memory;
    made.* = .{ .device = _objects.of(Device, device) };
    cache.* = _objects.handle(facet.PipelineCache, made);
    return .success;
}
