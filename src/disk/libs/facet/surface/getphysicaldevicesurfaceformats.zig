// SPDX-License-Identifier: MIT
//! GetPhysicalDeviceSurfaceFormats: the formats a surface's images can have.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _surface = @import("_surface.zig");
const Surface = _surface.Surface;

/// The formats a swapchain on the surface can have into `formats`, at most
/// `count.*` of them, and how many there are into `count`; null for
/// `formats` counts alone.
///
/// SYNOPSIS:
/// ```zig
/// fn GetPhysicalDeviceSurfaceFormats(base: *FacetBase, physical: *facet.PhysicalDevice, surface: *facet.Surface, count: *u32, formats: ?[*]facet.SurfaceFormat) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -336.
///
/// INPUTS:
/// - `physical` - the physical device.
/// - `surface` - the surface.
/// - `count` - how many `formats` has room for; how many were written.
/// - `formats` - where they go, or null.
///
/// RESULT:
/// `success`, or `incomplete` when `formats` was too short for them all.
///
/// BEHAVIOR:
/// A surface has one format, its display's: `b8g8r8a8_unorm` or
/// `r8g8b8a8_unorm`, in sRGB. A display of another, such as the 16-bit
/// panels, has none: facet.library draws 32 bits a pixel.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// None.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateSwapchain`
///
/// EXAMPLES:
/// ```zig
/// var count: u32 = 1;
/// var format: facet.SurfaceFormat = undefined;
/// _ = fb.GetPhysicalDeviceSurfaceFormats(physical, surface.?, &count, @ptrCast(&format));
/// if (count == 0) return error.NotThirtyTwoBits;
/// ```
pub fn GetPhysicalDeviceSurfaceFormats(base: *FacetBase, physical: *facet.PhysicalDevice, surface: *facet.Surface, count: *u32, formats: ?[*]facet.SurfaceFormat) facet.Result {
    _ = base;
    _ = physical;
    const made = _objects.of(Surface, surface);
    const format = made.ops.shape(made).format;
    const there: u32 = @intFromBool(_surface.drawable(format));
    const into = formats orelse {
        count.* = there;
        return .success;
    };
    if (count.* < there) {
        count.* = 0;
        return .incomplete;
    }
    if (there != 0) into[0] = .{ .format = format, .color_space = .srgb_nonlinear };
    count.* = there;
    return .success;
}
