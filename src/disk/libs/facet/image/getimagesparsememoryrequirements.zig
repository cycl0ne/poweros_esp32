// SPDX-License-Identifier: MIT
//! GetImageSparseMemoryRequirements: what binding a sparse image asks of
//! memory.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;

/// What binding an image sparsely asks of memory: nothing, no image being
/// sparse.
///
/// SYNOPSIS:
/// ```zig
/// fn GetImageSparseMemoryRequirements(base: *FacetBase, device: *facet.Device, image: *facet.Image, count: *u32, requirements: ?[*]facet.SparseImageMemoryRequirements) void
/// ```
///
/// SINCE: 1.124. LVO -540.
///
/// INPUTS:
/// - `device` - the device the image was made on.
/// - `image` - the image.
/// - `count` - set to 0.
/// - `requirements` - not written; may be null.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// An image is sparse only where it was made with
/// `IMAGE_CREATE_SPARSE_RESIDENCY`, which no device of this library takes,
/// its `sparse_residency_*` features being false: "If the image was not
/// created with VK_IMAGE_CREATE_SPARSE_RESIDENCY_BIT then
/// pSparseMemoryRequirementCount will be zero and pSparseMemoryRequirements
/// will not be written to" (the sparse resources chapter). That is v3dv's
/// answer (`v3dv_GetImageSparseMemoryRequirements`,
/// v3dv_device.c:3430-3438). Vulkan has the call carried all the same.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The image and `count` stay the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetImageMemoryRequirements`, `GetPhysicalDeviceSparseImageFormatProperties`
///
/// EXAMPLES:
/// ```zig
/// var count: u32 = 0;
/// fb.GetImageSparseMemoryRequirements(device, image, &count, null);
/// ```
pub fn GetImageSparseMemoryRequirements(base: *FacetBase, device: *facet.Device, image: *facet.Image, count: *u32, requirements: ?[*]facet.SparseImageMemoryRequirements) void {
    _ = base;
    _ = device;
    _ = image;
    _ = requirements;
    count.* = 0;
}
