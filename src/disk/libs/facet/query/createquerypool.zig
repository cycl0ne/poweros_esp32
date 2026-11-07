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
/// got (`Capabilities.occlusion_queries`, `pipeline_statistics_queries`),
/// or for a bit that is none of Vulkan's; `error_initialization_failed`
/// for no queries at all, or a statistics pool that counts nothing;
/// `error_out_of_host_memory`. A geometry shader's two statistics may be
/// asked for since 1.43, there being no such stage to count: they read 0,
/// which is what Vulkan has a statistic of a stage that never ran hold. A
/// timestamp pool is made on every device since 1.93, with a clock or
/// without one: see below.
///
/// BEHAVIOR:
/// A query holds one value, or for `pipeline_statistics` one for each
/// statistic asked for, in the order of their bits, and a value is 64 bits
/// wide since 1.122. A counter is kept in a lane for each part the cores
/// draw a frame's tiles in and added up when it is read, which is how
/// llvmpipe keeps one for each of its threads (lp_query.h:45-46): it takes
/// 32 bytes of the pool, a timestamp 8. Every query starts not available
/// and counting nothing, as `CmdResetQueryPool` leaves it; Vulkan asks for
/// a reset before a query is used all the same, and a program that means
/// to be read elsewhere should do it.
///
/// Which kinds a device has is what it counts with: an occlusion query is
/// counted by the rasterizer on the cores and by the hardware's own counter
/// on the V3D, which every device has since 1.47; the statistics are the
/// calls round the rasterizer, so they are the cores' alone; and a
/// timestamp is the E-clock read as the command is played, which every
/// device does where the machine has timer.device.
///
/// Without timer.device there is no clock to read, and the device says so
/// as Vulkan has a device say it: `QueueFamilyProperties.timestamp_valid_bits`
/// and `PhysicalDeviceLimits.timestamp_period` are 0, and
/// `timestamp_compute_and_graphics` is false. The pool is made all the
/// same. Vulkan gives `vkCreateQueryPool` no way to refuse a kind, and a
/// program learns what its queue can time from the queue family; until
/// 1.93 the pool was refused here. What a timestamp written into it reads
/// is `CmdWriteTimestamp`'s.
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
    const can = owner.physical.can;
    switch (info.query_type) {
        .occlusion => if (!can.occlusion_queries) return .error_feature_not_present,
        .pipeline_statistics => {
            if (!can.pipeline_statistics_queries) return .error_feature_not_present;
            if (info.pipeline_statistics & ~facet.QUERY_PIPELINE_STATISTIC_ALL != 0) return .error_feature_not_present;
            if (info.pipeline_statistics == 0) return .error_initialization_failed;
        },
        // With a clock or without: without one, the queue family's
        // timestamp_valid_bits of 0 is what says so (CmdWriteTimestamp).
        .timestamp => {},
        else => return .error_feature_not_present,
    }
    if (info.query_count == 0) return .error_initialization_failed;
    const made = _query.make(base.sys_base, owner, info) orelse return .error_out_of_host_memory;
    pool.* = _objects.handle(facet.QueryPool, made);
    return .success;
}
