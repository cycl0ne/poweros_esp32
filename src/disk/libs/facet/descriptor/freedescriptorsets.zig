// SPDX-License-Identifier: MIT
//! FreeDescriptorSets: descriptor sets given back to their pool.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _descriptor = @import("_descriptor.zig");

/// `count` descriptor sets given back to the pool they came from.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeDescriptorSets(base: *FacetBase, device: *facet.Device, pool: *facet.DescriptorPool, count: u32, sets: [*]const ?*facet.DescriptorSet) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -260.
///
/// INPUTS:
/// - `device` - the device.
/// - `pool` - the pool they were allocated from.
/// - `count`, `sets` - the sets; a null among them is passed over.
///
/// RESULT:
/// `success`.
///
/// BEHAVIOR:
/// No command buffer still pending may have bound one of them.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The sets are gone, and the pool may give out as many again.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocateDescriptorSets`, `ResetDescriptorPool`
///
/// EXAMPLES:
/// ```zig
/// _ = fb.FreeDescriptorSets(device, pool.?, 1, @ptrCast(&set));
/// ```
pub fn FreeDescriptorSets(base: *FacetBase, device: *facet.Device, pool: *facet.DescriptorPool, count: u32, sets: [*]const ?*facet.DescriptorSet) facet.Result {
    _ = device;
    _ = pool;
    for (sets[0..count]) |set| _descriptor.freeSet(base.sys_base, _objects.of(_descriptor.Set, set orelse continue));
    return .success;
}
