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
/// `success`, or `incomplete` when `formats` was too short for them all;
/// `error_surface_lost`, and none, when the window the surface is over has
/// closed.
///
/// BEHAVIOR:
/// A surface has one format, its display's: `b8g8r8a8_unorm`,
/// `r8g8b8a8_unorm` or `r5g6b5_unorm_pack16`, in sRGB. A display of
/// another - 24 bits, 1555, a palette's - has none. In 565 what is drawn
/// is drawn and blended in 8 bits a channel, as in the 32-bit formats,
/// and dithered into the display's pixels as it is stored
/// (CmdBeginRenderPass).
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
    const format = (made.ops.shape(made) orelse {
        count.* = 0;
        return .error_surface_lost;
    }).format;
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
