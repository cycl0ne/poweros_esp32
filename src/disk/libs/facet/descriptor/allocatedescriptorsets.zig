// SPDX-License-Identifier: MIT
//! AllocateDescriptorSets: descriptor sets from a pool.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _descriptor = @import("_descriptor.zig");

/// A descriptor set for each layout `info` names, into `sets`.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocateDescriptorSets(base: *FacetBase, device: *facet.Device, info: *const facet.DescriptorSetAllocateInfo, sets: [*]?*facet.DescriptorSet) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -256.
///
/// INPUTS:
/// - `device` - the device.
/// - `info` - the pool, and a layout for each set.
/// - `sets` - where the sets are written, one for each layout; all null
///   when it fails.
///
/// RESULT:
/// `success`; `error_out_of_pool_memory` when the pool has given out its
/// most; `error_out_of_host_memory`. Either way none is allocated.
///
/// BEHAVIOR:
/// A set's descriptors start empty: a shader reads null for each until it
/// is written (UpdateDescriptorSets).
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The sets are the pool's: they go with it, with ResetDescriptorPool or
/// with FreeDescriptorSets.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UpdateDescriptorSets`, `CmdBindDescriptorSets`, `FreeDescriptorSets`
///
/// EXAMPLES:
/// ```zig
/// var set: ?*facet.DescriptorSet = null;
/// _ = fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, @ptrCast(&set));
/// ```
pub fn AllocateDescriptorSets(base: *FacetBase, device: *facet.Device, info: *const facet.DescriptorSetAllocateInfo, sets: [*]?*facet.DescriptorSet) facet.Result {
    _ = device;
    const pool = _objects.of(_descriptor.Pool, info.descriptor_pool);
    const count = info.descriptor_set_count;
    for (sets[0..count]) |*set| set.* = null;
    const result: facet.Result = for (info.set_layouts[0..count], 0..) |layout, k| {
        if (pool.count >= pool.max_sets) break .error_out_of_pool_memory;
        const made = _descriptor.makeSet(base.sys_base, pool, _objects.of(_descriptor.SetLayout, layout)) orelse break .error_out_of_host_memory;
        _descriptor.link(made);
        sets[k] = _objects.handle(facet.DescriptorSet, made);
    } else return .success;
    for (sets[0..count]) |*set| {
        _descriptor.freeSet(base.sys_base, _objects.of(_descriptor.Set, set.* orelse continue));
        set.* = null;
    }
    return result;
}
