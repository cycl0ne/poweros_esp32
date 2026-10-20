// SPDX-License-Identifier: MIT
//! GetPhysicalDeviceFormatProperties: what a device does with a format.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _image = @import("../image/_image.zig");

/// What the device does with a format, in each tiling and in a buffer.
///
/// SYNOPSIS:
/// ```zig
/// fn GetPhysicalDeviceFormatProperties(base: *FacetBase, physical: *facet.PhysicalDevice, format: facet.Format, properties: *facet.FormatProperties) void
/// ```
///
/// SINCE: 1.0. LVO -72.
///
/// INPUTS:
/// - `physical` - a physical device EnumeratePhysicalDevices listed.
/// - `format` - the format.
/// - `properties` - where its features are written: none for a format
///   facet.library does not know.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// - B8G8R8A8_UNORM and R8G8B8A8_UNORM: colour attachments, blended, in
///   either tiling; sampled, filtered, in optimal tiling; copied to and
///   from; a vertex's value.
/// - R5G6B5_UNORM_PACK16: sampled, filtered, in optimal tiling; copied.
/// - D16_UNORM: a depth attachment, in optimal tiling.
/// - R32_SFLOAT to R32G32B32A32_SFLOAT: a vertex's value.
///
/// An image to be sampled has sides that are powers of two.
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
/// A colour attachment is not sampled as well: the two lie differently in
/// memory (CreateImage).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateImage`
///
/// EXAMPLES:
/// ```zig
/// var properties: facet.FormatProperties = undefined;
/// fb.GetPhysicalDeviceFormatProperties(physical, .r5g6b5_unorm_pack16, &properties);
/// const can_sample = properties.optimal_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE != 0;
/// ```
pub fn GetPhysicalDeviceFormatProperties(base: *FacetBase, physical: *facet.PhysicalDevice, format: facet.Format, properties: *facet.FormatProperties) void {
    _ = base;
    _ = physical;
    properties.* = _image.propertiesOf(format);
}
