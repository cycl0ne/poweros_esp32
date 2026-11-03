// SPDX-License-Identifier: MIT
//! CreateQueryPool: where what a frame's work came to is counted.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const _query = @import("_query.zig");

/// A query pool: `query_count` queries of one kind, nothing counted yet.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateQueryPool(base: *FacetBase, device: *facet.Device, info: *const facet.QueryPoolCreateInfo, pool: *?*facet.QueryPool) facet.Result
/// ```
///
/// SINCE: 1.29. LVO -456.
///
/// INPUTS:
/// - `device` - the device whose work is counted.
/// - `info` - the kind, how many queries, and for `pipeline_statistics`
///   which statistics each one counts.
/// - `pool` - where the pool is written; null when it fails.
///
/// RESULT:
/// `success`; `error_feature_not_present` for a kind this device has not
/// got (`PhysicalDeviceFeatures.occlusion_queries`,
/// `pipeline_statistics_queries`, `timestamp_queries`), or for a bit that
/// is none of Vulkan's; `error_initialization_failed` for no queries at
/// all, or a statistics pool that counts nothing;
/// `error_out_of_host_memory`. A geometry shader's two statistics may be
/// asked for since 1.43, there being no such stage to count: they read 0,
/// which is what Vulkan has a statistic of a stage that never ran hold.
///
/// BEHAVIOR:
/// A query holds one value, or for `pipeline_statistics` one for each
/// statistic asked for, in the order of their bits. Every query starts not
/// available and counting nothing, as `CmdResetQueryPool` leaves it; Vulkan
/// asks for a reset before a query is used all the same, and a program that
/// means to be read elsewhere should do it.
///
/// Which kinds a device has is what it counts with: the occlusion and the
/// statistics are counted by the rasterizer and the calls round it, so they
/// are the cores'; a timestamp is the E-clock read as the command is
/// played, which every device does - where the machine has timer.device, or
/// there is no clock to read and the kind is refused.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pool is the caller's, until DestroyQueryPool. Its values are written
/// by the queue's task and by the cores that draw the tiles, so it has to
/// last until the work that names it is done.
///
/// NOTES:
/// There is one pool for each kind, as in Vulkan: a pool of statistics does
/// not also count samples.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdBeginQuery`, `CmdWriteTimestamp`, `GetQueryPoolResults`,
/// `DestroyQueryPool`
///
/// EXAMPLES:
/// ```zig
/// var counted: ?*facet.QueryPool = null;
/// _ = fb.CreateQueryPool(device, &.{ .query_type = .occlusion, .query_count = 1 }, &counted);
/// ```
pub fn CreateQueryPool(base: *FacetBase, device: *facet.Device, info: *const facet.QueryPoolCreateInfo, pool: *?*facet.QueryPool) facet.Result {
    pool.* = null;
    const owner = _objects.of(Device, device);
    const features = owner.physical.features;
    switch (info.query_type) {
        .occlusion => if (!features.occlusion_queries) return .error_feature_not_present,
        .pipeline_statistics => {
            if (!features.pipeline_statistics_queries) return .error_feature_not_present;
            if (info.pipeline_statistics & ~facet.QUERY_PIPELINE_STATISTIC_ALL != 0) return .error_feature_not_present;
            if (info.pipeline_statistics == 0) return .error_initialization_failed;
        },
        .timestamp => if (!features.timestamp_queries) return .error_feature_not_present,
        else => return .error_feature_not_present,
    }
    if (info.query_count == 0) return .error_initialization_failed;
    const made = _query.make(base.sys_base, owner, info) orelse return .error_out_of_host_memory;
    pool.* = _objects.handle(facet.QueryPool, made);
    return .success;
}
