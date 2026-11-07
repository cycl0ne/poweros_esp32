// SPDX-License-Identifier: MIT
//! GetPipelineCacheData: what a pipeline cache holds, to keep for another
//! run.

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;

/// What a pipeline cache holds, as bytes to keep and give to another
/// CreatePipelineCache: Vulkan's header of 32 bytes, and nothing after it.
///
/// SYNOPSIS:
/// ```zig
/// fn GetPipelineCacheData(base: *FacetBase, device: *facet.Device, cache: *facet.PipelineCache, size: *usize, data: ?*anyopaque) facet.Result
/// ```
///
/// SINCE: 1.130. LVO -588.
///
/// INPUTS:
/// - `device` - the device it was made on.
/// - `cache` - the cache.
/// - `size` - the bytes there is room for at `data`; set to the bytes
///   written, or with `data` null to the bytes there are.
/// - `data` - where they are written, or null.
///
/// RESULT:
/// `success`; `incomplete` where there is no room for the header, and
/// then nothing is written and `size` is 0.
///
/// BEHAVIOR:
/// The header is `PipelineCacheHeaderVersionOne`, its numbers least
/// significant byte first as Vulkan has them whatever the machine: its
/// size, version one, and the device's `vendor_id`, `device_id` and
/// `pipeline_cache_uuid` (PhysicalDeviceProperties), as lavapipe writes
/// its own (`lvp_GetPipelineCacheData`, lvp_pipeline_cache.c:70-94). No
/// pipeline follows it, the cache holding none.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bytes are the caller's.
///
/// NOTES:
/// The UUID moves with the library's revision (`_driver.cacheUuid`), so
/// data kept from another build of it is told apart.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreatePipelineCache`, `GetPhysicalDeviceProperties`
///
/// EXAMPLES:
/// ```zig
/// var size: usize = 0;
/// _ = fb.GetPipelineCacheData(device, cache.?, &size, null);
/// ```
pub fn GetPipelineCacheData(base: *FacetBase, device: *facet.Device, cache: *facet.PipelineCache, size: *usize, data: ?*anyopaque) facet.Result {
    _ = base;
    _ = cache;
    const bytes = @sizeOf(facet.PipelineCacheHeaderVersionOne);
    const into: [*]u8 = @ptrCast(data orelse {
        size.* = bytes;
        return .success;
    });
    if (size.* < bytes) {
        size.* = 0;
        return .incomplete;
    }
    const properties = &_objects.of(Device, device).physical.properties;
    std.mem.writeInt(u32, into[0..4], bytes, .little);
    std.mem.writeInt(u32, into[4..8], @intFromEnum(facet.PipelineCacheHeaderVersion.one), .little);
    std.mem.writeInt(u32, into[8..12], properties.vendor_id, .little);
    std.mem.writeInt(u32, into[12..16], properties.device_id, .little);
    into[16..32].* = properties.pipeline_cache_uuid;
    size.* = bytes;
    return .success;
}
