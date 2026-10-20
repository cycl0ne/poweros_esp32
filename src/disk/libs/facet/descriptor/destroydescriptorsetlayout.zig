// SPDX-License-Identifier: MIT
//! DestroyDescriptorSetLayout: a descriptor set layout given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const SetLayout = @import("_descriptor.zig").SetLayout;

/// The descriptor set layout given back; the sets allocated with it stay.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroyDescriptorSetLayout(base: *FacetBase, device: *facet.Device, layout: ?*facet.DescriptorSetLayout) void
/// ```
///
/// SINCE: 1.0. LVO -232.
///
/// INPUTS:
/// - `device` - the device.
/// - `layout` - a layout CreateDescriptorSetLayout made, or null, which
///   does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A set keeps what it needs of its layout; so does a pipeline layout.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The layout is gone.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateDescriptorSetLayout`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroyDescriptorSetLayout(device, set_layout);
/// ```
pub fn DestroyDescriptorSetLayout(base: *FacetBase, device: *facet.Device, layout: ?*facet.DescriptorSetLayout) void {
    _ = device;
    _objects.destroy(base.sys_base, _objects.of(SetLayout, layout orelse return));
}
