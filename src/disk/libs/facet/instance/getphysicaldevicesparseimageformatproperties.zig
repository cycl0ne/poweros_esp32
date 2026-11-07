// SPDX-License-Identifier: MIT
//! GetPhysicalDeviceSparseImageFormatProperties: the blocks a sparse image
//! of a format is bound in.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;

/// The blocks a sparse image of a format, type, sample count, usage and
/// tiling would be bound in: none, no device having a sparse image.
///
/// SYNOPSIS:
/// ```zig
/// fn GetPhysicalDeviceSparseImageFormatProperties(base: *FacetBase, physical: *facet.PhysicalDevice, format: facet.Format, image_type: facet.ImageType, samples: u32, usage: u32, tiling: facet.ImageTiling, count: *u32, properties: ?[*]facet.SparseImageFormatProperties) void
/// ```
///
/// SINCE: 1.124. LVO -536.
///
/// INPUTS:
/// - `physical` - the device.
/// - `format`, `image_type`, `samples`, `usage`, `tiling` - the image, as
///   CreateImage would be given it with `IMAGE_CREATE_SPARSE_RESIDENCY`.
/// - `count` - set to 0.
/// - `properties` - not written; may be null.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// No device of this library binds memory sparsely: `sparse_binding` and
/// the eight `sparse_residency_*` features are false. So no format has a
/// sparse image, and the count is 0 whatever is asked about: "If
/// VK_IMAGE_CREATE_SPARSE_RESIDENCY_BIT is not supported for the given
/// arguments, pPropertyCount will be zero upon return, and no data will be
/// written to pProperties" (the sparse resources chapter). That is v3dv's
/// answer (`v3dv_GetPhysicalDeviceSparseImageFormatProperties`,
/// v3dv_formats.c:818-829). Vulkan has the call carried all the same.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `count` stays the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetImageSparseMemoryRequirements`, `GetPhysicalDeviceFeatures`
///
/// EXAMPLES:
/// ```zig
/// var count: u32 = 0;
/// fb.GetPhysicalDeviceSparseImageFormatProperties(physical, .r8g8b8a8_unorm, .@"2d", 1, facet.IMAGE_USAGE_SAMPLED, .optimal, &count, null);
/// ```
pub fn GetPhysicalDeviceSparseImageFormatProperties(base: *FacetBase, physical: *facet.PhysicalDevice, format: facet.Format, image_type: facet.ImageType, samples: u32, usage: u32, tiling: facet.ImageTiling, count: *u32, properties: ?[*]facet.SparseImageFormatProperties) void {
    _ = base;
    _ = physical;
    _ = format;
    _ = image_type;
    _ = samples;
    _ = usage;
    _ = tiling;
    _ = properties;
    count.* = 0;
}
