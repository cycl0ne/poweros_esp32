// SPDX-License-Identifier: MIT
//! GetPhysicalDeviceSurfaceCapabilities: what a surface can be given.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _surface = @import("_surface.zig");
const Surface = _surface.Surface;
const max_images = @import("../swapchain/_swapchain.zig").max_images;

/// What a swapchain on the surface can be, into `capabilities`.
///
/// SYNOPSIS:
/// ```zig
/// fn GetPhysicalDeviceSurfaceCapabilities(base: *FacetBase, physical: *facet.PhysicalDevice, surface: *facet.Surface, capabilities: *facet.SurfaceCapabilities) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -332.
///
/// INPUTS:
/// - `physical` - the physical device.
/// - `surface` - the surface.
/// - `capabilities` - filled in.
///
/// RESULT:
/// `success`; `error_surface_lost`, and nothing written, when the window
/// the surface is over has closed.
///
/// BEHAVIOR:
/// A swapchain on a screen is the screen's size, which is its display's,
/// and has from one image to as many pictures as the display's memory
/// holds, four at most. One on a window is the size inside the window's
/// border now, and has from one image to four. Its images are drawn into,
/// and shown as they are drawn: no transform, no alpha.
///
/// CONTEXT:
/// - Waits: on a window's surface, for the screens' semaphore.
/// - Interrupts: no.
/// - Locks: on a window's surface, no layer's lock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// None.
///
/// NOTES:
/// The display's memory is shared with every other screen open, each of
/// which takes a picture of it: max_image_count is the most there could be,
/// and CreateSwapchain says whether there is room now.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateSwapchain`
///
/// EXAMPLES:
/// ```zig
/// var capabilities: facet.SurfaceCapabilities = undefined;
/// _ = fb.GetPhysicalDeviceSurfaceCapabilities(physical, surface.?, &capabilities);
/// const extent = capabilities.current_extent;
/// ```
pub fn GetPhysicalDeviceSurfaceCapabilities(base: *FacetBase, physical: *facet.PhysicalDevice, surface: *facet.Surface, capabilities: *facet.SurfaceCapabilities) facet.Result {
    _ = base;
    _ = physical;
    const made = _objects.of(Surface, surface);
    const now = made.ops.shape(made) orelse return .error_surface_lost;
    const extent = facet.Extent2D{ .width = now.width, .height = now.height };
    capabilities.* = .{
        .min_image_count = 1,
        .max_image_count = @min(made.ops.most(made), max_images),
        .current_extent = extent,
        .min_image_extent = extent,
        .max_image_extent = extent,
        .max_image_array_layers = 1,
        .supported_transforms = facet.SURFACE_TRANSFORM_IDENTITY,
        .current_transform = facet.SURFACE_TRANSFORM_IDENTITY,
        .supported_composite_alpha = facet.COMPOSITE_ALPHA_OPAQUE,
        .supported_usage_flags = _surface.usage,
    };
    return .success;
}
