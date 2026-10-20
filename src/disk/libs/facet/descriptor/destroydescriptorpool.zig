// SPDX-License-Identifier: MIT
//! DestroyDescriptorPool: a descriptor pool given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _descriptor = @import("_descriptor.zig");

/// The descriptor pool given back, and every set allocated from it.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroyDescriptorPool(base: *FacetBase, device: *facet.Device, pool: ?*facet.DescriptorPool) void
/// ```
///
/// SINCE: 1.0. LVO -248.
///
/// INPUTS:
/// - `device` - the device.
/// - `pool` - a pool CreateDescriptorPool made, or null, which does
///   nothing.
///
/// RESULT:
/// None.
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
/// The pool is gone, and its sets.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateDescriptorPool`, `ResetDescriptorPool`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroyDescriptorPool(device, pool);
/// ```
pub fn DestroyDescriptorPool(base: *FacetBase, device: *facet.Device, pool: ?*facet.DescriptorPool) void {
    _ = device;
    const made = _objects.of(_descriptor.Pool, pool orelse return);
    _descriptor.freeAll(base.sys_base, made);
    _objects.destroy(base.sys_base, made);
}
