// SPDX-License-Identifier: MIT
//! CreateScreenSurface: a surface over a screen.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Instance = @import("../instance/_instance.zig").Instance;
const Surface = @import("_surface.zig").Surface;
const screen = @import("screen.zig");

/// A surface over a screen the program has opened, written to `surface`.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateScreenSurface(base: *FacetBase, instance: *facet.Instance, info: *const facet.ScreenSurfaceCreateInfo, surface: *?*facet.Surface) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -320.
///
/// INPUTS:
/// - `instance` - the instance.
/// - `info` - the screen, the whole of which the surface is.
/// - `surface` - where the surface goes; null when none was made.
///
/// RESULT:
/// `success`; `error_initialization_failed` without intuition.library, or
/// without rtg.library 1.5 or newer; `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// A swapchain made on the surface has the screen's buffers as its
/// images: the first is the screen's own buffer, the one its bar and windows
/// are drawn in, and the rest are made in the display's memory as
/// AllocScreenBuffer makes them. Presenting an image is ChangeScreenBuffer:
/// the display takes it up at the start of its next frame. The screen can be
/// pulled down, put behind another and brought forward as before.
///
/// intuition.library and rtg.library are opened for as long as the surface
/// lasts.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The surface is the caller's, to give back with `DestroySurface` before
/// the screen closes and before the instance goes. The screen stays the
/// caller's.
///
/// NOTES:
/// A screen whose pixels are neither 32 bits nor 565 has no format
/// facet.library draws in: GetPhysicalDeviceSurfaceFormats lists none for
/// it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DestroySurface`, `GetPhysicalDeviceSurfaceCapabilities`, `CreateSwapchain`
///
/// EXAMPLES:
/// ```zig
/// var surface: ?*facet.Surface = null;
/// if (fb.CreateScreenSurface(instance, &.{ .screen = screen }, &surface) != .success) return error.NoSurface;
/// defer fb.DestroySurface(instance, surface);
/// ```
pub fn CreateScreenSurface(base: *FacetBase, instance: *facet.Instance, info: *const facet.ScreenSurfaceCreateInfo, surface: *?*facet.Surface) facet.Result {
    surface.* = null;
    const owner = _objects.of(Instance, instance);
    const sys = base.sys_base;
    const made = _objects.create(sys, Surface) orelse return .error_out_of_host_memory;
    made.* = .{ .instance = owner, .ops = &screen.ops };
    const opened = screen.open(sys, made, info.screen);
    if (opened != .success) {
        _objects.destroy(sys, made);
        return opened;
    }
    owner.surfaces += 1;
    surface.* = _objects.handle(facet.Surface, made);
    return .success;
}
