// SPDX-License-Identifier: MIT
//! DestroyImage: an image given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Image = @import("_image.zig").Image;

/// The image given back.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroyImage(base: *FacetBase, device: *facet.Device, image: ?*facet.Image) void
/// ```
///
/// SINCE: 1.0. LVO -96.
///
/// INPUTS:
/// - `device` - the device it was made on.
/// - `image` - the image, or null, which does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// No work the queue has not finished may use it, and its views go
/// first. The memory it was bound into stays as it is. A swapchain's
/// image is left alone: it goes with the swapchain.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The image is gone; its memory is still the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateImage`, `DestroyImageView`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroyImage(device, picture);
/// ```
pub fn DestroyImage(base: *FacetBase, device: *facet.Device, image: ?*facet.Image) void {
    _ = device;
    const made = _objects.of(Image, image orelse return);
    // A swapchain's goes with the swapchain.
    if (made.presentable) return;
    _objects.destroy(base.sys_base, made);
}
