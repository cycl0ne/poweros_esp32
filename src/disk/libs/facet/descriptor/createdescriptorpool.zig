// SPDX-License-Identifier: MIT
//! CreateDescriptorPool: where descriptor sets come from.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const Pool = @import("_descriptor.zig").Pool;

/// A descriptor pool: the most sets it gives out at once.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateDescriptorPool(base: *FacetBase, device: *facet.Device, info: *const facet.DescriptorPoolCreateInfo, pool: *?*facet.DescriptorPool) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -244.
///
/// INPUTS:
/// - `device` - the device.
/// - `info` - the most sets, the descriptors of each kind, and whether its
///   sets may be freed one by one.
/// - `pool` - where the pool is written; null when it fails.
///
/// RESULT:
/// `success`; `error_initialization_failed` for a pool of no sets;
/// `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// The pool counts the sets it has given out against `max_sets`. The
/// descriptors of each kind are not counted: a set takes what its layout
/// needs, from the caller's memory, as it is allocated.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pool is the caller's, until DestroyDescriptorPool, and the sets it
/// gives out are the pool's.
///
/// NOTES:
/// Sets may be freed one by one whether or not the pool was made with
/// DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocateDescriptorSets`, `ResetDescriptorPool`, `DestroyDescriptorPool`
///
/// EXAMPLES:
/// ```zig
/// const size = facet.DescriptorPoolSize{ .type = .sampled_image, .descriptor_count = 4 };
/// var pool: ?*facet.DescriptorPool = null;
/// _ = fb.CreateDescriptorPool(device, &.{ .max_sets = 4, .pool_size_count = 1, .pool_sizes = @ptrCast(&size) }, &pool);
/// ```
pub fn CreateDescriptorPool(base: *FacetBase, device: *facet.Device, info: *const facet.DescriptorPoolCreateInfo, pool: *?*facet.DescriptorPool) facet.Result {
    pool.* = null;
    const owner = _objects.of(Device, device);
    if (info.max_sets == 0) return .error_initialization_failed;
    const made = _objects.create(base.sys_base, Pool) orelse return .error_out_of_host_memory;
    made.* = .{ .device = owner, .flags = info.flags, .max_sets = info.max_sets };
    pool.* = _objects.handle(facet.DescriptorPool, made);
    return .success;
}
