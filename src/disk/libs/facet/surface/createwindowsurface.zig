// SPDX-License-Identifier: MIT
//! CreateWindowSurface: a surface over the inside of a window.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Instance = @import("../instance/_instance.zig").Instance;
const Surface = @import("_surface.zig").Surface;
const window = @import("window.zig");

/// A surface over the inside of a window the program has opened, written
/// to `surface`.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateWindowSurface(base: *FacetBase, instance: *facet.Instance, info: *const facet.WindowSurfaceCreateInfo, surface: *?*facet.Surface) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -364.
///
/// INPUTS:
/// - `instance` - the instance.
/// - `info` - the window, whose inside - within its border - the surface is.
/// - `surface` - where the surface goes; null when none was made.
///
/// RESULT:
/// `success`; `error_initialization_failed` without intuition.library,
/// graphics.library, layers.library or rtg.library, or with an
/// intuition.library that does not number its windows (before 0.47);
/// `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// A swapchain made on the surface has pictures in memory as its images,
/// the size of the window inside its border when the swapchain is made.
/// Presenting one waits for the display's next frame and copies the picture
/// into the window, through the window's layer, which is held meanwhile:
/// what covers the window is left alone, and the board's engine does the
/// copying. Copied as the frame starts, the picture is in place before the
/// display reads that part of the screen, so the window never shows half of
/// one picture and half of the next; a present is shown a frame at most
/// after the one before. An image is free again as soon as it is copied, so
/// a swapchain of one image is drawn, copied and drawn again, and one of two
/// is drawn while the other waits for its frame.
///
/// The window can be moved, put behind others and brought forward while
/// the swapchain is in use: each picture lands where the window is then.
/// Once it is made bigger or smaller, the swapchain is out of date:
/// AcquireNextImage and QueuePresent answer `error_out_of_date`, and a new
/// swapchain of the new size is made, the old one handed to it as
/// `old_swapchain`. A picture presented after the window was made smaller
/// and before that is cut to the window's inside.
///
/// The window is found by its number (`WA_Number`) each time it is read or
/// drawn into, so a window that closes under the surface is never drawn
/// into once it has gone. That is what happens to a program that ends -
/// returns, or is stopped by a fault - with its window open while facet's
/// queue still has a frame of it to show: intuition closes the window, the
/// frame is not copied, and AcquireNextImage, QueuePresent, CreateSwapchain
/// and the surface queries answer `error_surface_lost` from then on. The
/// swapchain and the surface are still destroyed as before.
///
/// intuition.library, graphics.library, layers.library and rtg.library are
/// opened for as long as the surface lasts.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed; while the surface lasts, the calls that read or
///   show on it take the screens' semaphore (`LockIBase`), so they are
///   never made holding a layer's lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The surface is the caller's, to give back with `DestroySurface` before
/// the window closes and before the instance goes. The window stays the
/// caller's: its IDCMP messages, its gadgets and its border too. What the
/// program draws into the window's inside itself is drawn over by the next
/// picture.
///
/// NOTES:
/// A window on a screen whose pixels are neither 32 bits nor 565 has no
/// format facet.library draws in: GetPhysicalDeviceSurfaceFormats lists
/// none for it. A simple-refresh window with `WA_NoCareRefresh` keeps no copy of its
/// covered parts, which the next picture draws anyway.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DestroySurface`, `CreateScreenSurface`, `CreateSwapchain`
///
/// EXAMPLES:
/// ```zig
/// var surface: ?*facet.Surface = null;
/// if (fb.CreateWindowSurface(instance, &.{ .window = window }, &surface) != .success) return error.NoSurface;
/// defer fb.DestroySurface(instance, surface);
/// ```
pub fn CreateWindowSurface(base: *FacetBase, instance: *facet.Instance, info: *const facet.WindowSurfaceCreateInfo, surface: *?*facet.Surface) facet.Result {
    surface.* = null;
    const owner = _objects.of(Instance, instance);
    const sys = base.sys_base;
    const made = _objects.create(sys, Surface) orelse return .error_out_of_host_memory;
    made.* = .{ .instance = owner, .ops = &window.ops };
    const opened = window.open(sys, made, info.window);
    if (opened != .success) {
        _objects.destroy(sys, made);
        return opened;
    }
    owner.surfaces += 1;
    surface.* = _objects.handle(facet.Surface, made);
    return .success;
}
