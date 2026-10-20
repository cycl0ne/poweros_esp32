// SPDX-License-Identifier: MIT
//! GetSwapchainImages: a swapchain's images.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _swapchain = @import("_swapchain.zig");
const Swapchain = _swapchain.Swapchain;

/// The swapchain's images into `images`, at most `count.*` of them, and how
/// many there are into `count`; null for `images` counts alone.
///
/// SYNOPSIS:
/// ```zig
/// fn GetSwapchainImages(base: *FacetBase, device: *facet.Device, swapchain: *facet.Swapchain, count: *u32, images: ?[*]*facet.Image) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -352.
///
/// INPUTS:
/// - `device` - the device it was made with.
/// - `swapchain` - the swapchain.
/// - `count` - how many `images` has room for; how many were written.
/// - `images` - where they go, or null.
///
/// RESULT:
/// `success`, or `incomplete` when `images` was too short for them all.
///
/// BEHAVIOR:
/// The images in the order AcquireNextImage and QueuePresent number them.
/// Views and framebuffers are made of them as of any colour attachment.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The images are the swapchain's, and go with it.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AcquireNextImage`, `CreateImageView`
///
/// EXAMPLES:
/// ```zig
/// var count: u32 = 4;
/// var images: [4]*facet.Image = undefined;
/// _ = fb.GetSwapchainImages(device, swapchain.?, &count, &images);
/// ```
pub fn GetSwapchainImages(base: *FacetBase, device: *facet.Device, swapchain: *facet.Swapchain, count: *u32, images: ?[*]*facet.Image) facet.Result {
    _ = base;
    _ = device;
    const made = _objects.of(Swapchain, swapchain);
    const into = images orelse {
        count.* = made.count;
        return .success;
    };
    const given = @min(count.*, made.count);
    for (into[0..given], made.images[0..given]) |*handle, *image| handle.* = _objects.handle(facet.Image, image);
    count.* = given;
    return if (given < made.count) .incomplete else .success;
}
