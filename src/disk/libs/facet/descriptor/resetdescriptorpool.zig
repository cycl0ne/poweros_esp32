// SPDX-License-Identifier: MIT
//! ResetDescriptorPool: every set of a pool freed.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _descriptor = @import("_descriptor.zig");

/// Every set allocated from the pool freed at once.
///
/// SYNOPSIS:
/// ```zig
/// fn ResetDescriptorPool(base: *FacetBase, device: *facet.Device, pool: *facet.DescriptorPool, flags: u32) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -252.
///
/// INPUTS:
/// - `device` - the device.
/// - `pool` - the pool.
/// - `flags` - 0.
///
/// RESULT:
/// `success`.
///
/// BEHAVIOR:
/// No command buffer still pending may have bound one of its sets.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The sets are gone; the pool is the caller's still.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocateDescriptorSets`, `FreeDescriptorSets`
///
/// EXAMPLES:
/// ```zig
/// _ = fb.ResetDescriptorPool(device, pool.?, 0);
/// ```
pub fn ResetDescriptorPool(base: *FacetBase, device: *facet.Device, pool: *facet.DescriptorPool, flags: u32) facet.Result {
    _ = device;
    _ = flags;
    _descriptor.freeAll(base.sys_base, _objects.of(_descriptor.Pool, pool));
    return .success;
}
