// SPDX-License-Identifier: MIT
//! GetPhysicalDeviceFormatProperties: what a device does with a format.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const PhysicalDevice = @import("_instance.zig").PhysicalDevice;

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
/// - R5G6B5_UNORM_PACK16: colour attachments, blended, in either tiling;
///   sampled, filtered, in optimal tiling; copied.
/// - D16_UNORM: a depth attachment, in optimal tiling.
/// - R32_SFLOAT to R32G32B32A32_SFLOAT: a vertex's value.
/// - BC1, BC2, BC3, R16G16B16A16_SFLOAT, R32G32B32A32_SFLOAT,
///   B10G11R11_UFLOAT and E5B9G9R9_UFLOAT: sampled, filtered, in optimal
///   tiling, and copied into. They are kept as 8 bits a channel, floats cut to
///   0 to 1: they save no memory and hold no more than B8G8R8A8.
///
/// An image to be sampled may have sides of any size (since 1.42).
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
    properties.* = _objects.of(PhysicalDevice, physical).ops.format_properties(format);
}
