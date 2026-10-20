// SPDX-License-Identifier: MIT
//! GetPhysicalDeviceProperties: what a physical device is.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const PhysicalDevice = @import("_instance.zig").PhysicalDevice;

/// What a physical device is, and the most it does.
///
/// SYNOPSIS:
/// ```zig
/// fn GetPhysicalDeviceProperties(base: *FacetBase, physical: *facet.PhysicalDevice, properties: *facet.PhysicalDeviceProperties) void
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `physical` - a physical device EnumeratePhysicalDevices listed.
/// - `properties` - where they are written.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The device is of type `cpu`, with no vendor or device ID; its name
/// says how many cores it shares a frame's tiles between, and so do its
/// limits (`cores`, with `tile_size`). `api_version` is the interface it
/// has, `driver_version` the library's own version and revision.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `properties` is the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `EnumeratePhysicalDevices`, `GetPhysicalDeviceMemoryProperties`
///
/// EXAMPLES:
/// ```zig
/// var properties: facet.PhysicalDeviceProperties = undefined;
/// fb.GetPhysicalDeviceProperties(physical, &properties);
/// ```
pub fn GetPhysicalDeviceProperties(base: *FacetBase, physical: *facet.PhysicalDevice, properties: *facet.PhysicalDeviceProperties) void {
    _ = base;
    properties.* = _objects.of(PhysicalDevice, physical).properties;
}
