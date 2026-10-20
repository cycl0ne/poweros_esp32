// SPDX-License-Identifier: MIT
//! CreateSwapchain: a surface's images, to draw and show in turn.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _swapchain = @import("_swapchain.zig");
const Swapchain = _swapchain.Swapchain;
const Device = @import("../device/_device.zig").Device;
const _surface = @import("../surface/_surface.zig");
const Surface = _surface.Surface;

/// A swapchain on a surface, written to `swapchain`.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateSwapchain(base: *FacetBase, device: *facet.Device, info: *const facet.SwapchainCreateInfo, swapchain: *?*facet.Swapchain) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -344.
///
/// INPUTS:
/// - `device` - the device whose queue presents its images.
/// - `info` - the surface, how many images at least, their format and size
///   - the surface's own, as GetPhysicalDeviceSurfaceFormats and
///   GetPhysicalDeviceSurfaceCapabilities give them - what they are used
///   for, the present mode, and the swapchain before it, if any.
/// - `swapchain` - where the swapchain goes; null when none was made.
///
/// RESULT:
/// `success`; `error_out_of_device_memory` when the display's memory has
/// no room for that many pictures; `error_native_window_in_use` when the
/// surface has a swapchain that is not `old_swapchain`;
/// `error_initialization_failed` for a size that is not the surface's;
/// `error_format_not_supported` for a format that is not its;
/// `error_feature_not_present` for a use, a present mode or layers it does
/// not have; `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// `min_image_count` images are made, at least one and at most four. On a
/// screen the first is the screen's own buffer, shown as the swapchain
/// starts; the rest are new buffers, black, made as AllocScreenBuffer makes
/// them. Each is an image of `rows`, bound already, its pixels the
/// buffer's: what is drawn into it is handed on to the display tile by tile
/// as the render pass ends.
///
/// `old_swapchain` is handed on: it hands out no more images
/// (AcquireNextImage answers `error_out_of_date`), and what it was given to
/// present is still shown. It is destroyed with DestroySwapchain as before.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The swapchain is the caller's, to give back with `DestroySwapchain`
/// before the surface goes. Its images are the swapchain's: they are not
/// bound, and not destroyed, by the program.
///
/// NOTES:
/// A display's memory holds a few pictures, and every screen open takes
/// one: on a display with room for three - Workbench's, the program's screen
/// and one more - two images is all there is. Make the new swapchain after
/// destroying the old one where both would not fit.
///
/// BUGS:
/// On a screen, a swapchain and the one it was handed on from share the
/// screen's own buffer as their first image.
///
/// SEE ALSO:
/// `DestroySwapchain`, `GetSwapchainImages`, `AcquireNextImage`, `QueuePresent`
///
/// EXAMPLES:
/// ```zig
/// var swapchain: ?*facet.Swapchain = null;
/// const result = fb.CreateSwapchain(device, &.{
///     .surface = surface.?,
///     .min_image_count = 2,
///     .image_format = format.format,
///     .image_extent = capabilities.current_extent,
/// }, &swapchain);
/// ```
pub fn CreateSwapchain(base: *FacetBase, device: *facet.Device, info: *const facet.SwapchainCreateInfo, swapchain: *?*facet.Swapchain) facet.Result {
    swapchain.* = null;
    const owner = _objects.of(Device, device);
    const sys = base.sys_base;
    const surface = _objects.of(Surface, info.surface);
    const old: ?*Swapchain = if (info.old_swapchain) |handle| _objects.of(Swapchain, handle) else null;
    if (surface.swapchain) |live| if (live != old) return .error_native_window_in_use;
    const now = surface.ops.shape(surface);
    if (info.image_extent.width != now.width or info.image_extent.height != now.height) return .error_initialization_failed;
    if (info.image_format != now.format or !_surface.drawable(now.format)) return .error_format_not_supported;
    if (info.image_usage & ~_surface.usage != 0 or info.image_array_layers != 1 or info.present_mode != .fifo) return .error_feature_not_present;
    const count = @max(1, @min(info.min_image_count, _swapchain.max_images));
    const made = _objects.create(sys, Swapchain) orelse return .error_out_of_host_memory;
    made.* = .{ .device = owner, .surface = surface, .width = now.width, .height = now.height, .format = now.format, .count = count };
    if (!surface.ops.make(surface, made.pictures[0..count])) {
        _objects.destroy(sys, made);
        return .error_out_of_device_memory;
    }
    _swapchain.lay(made, sys, info.image_usage);
    if (old) |previous| _swapchain.retire(previous, sys);
    surface.swapchain = made;
    surface.swapchains += 1;
    swapchain.* = _objects.handle(facet.Swapchain, made);
    return .success;
}
