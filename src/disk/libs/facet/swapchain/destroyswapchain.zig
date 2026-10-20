// SPDX-License-Identifier: MIT
//! DestroySwapchain: a swapchain given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _swapchain = @import("_swapchain.zig");
const Swapchain = _swapchain.Swapchain;
const _queue = @import("../queue/_queue.zig");

/// The swapchain given back, and its images.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroySwapchain(base: *FacetBase, device: *facet.Device, swapchain: ?*facet.Swapchain) void
/// ```
///
/// SINCE: 1.0. LVO -348.
///
/// INPUTS:
/// - `device` - the device it was made with.
/// - `swapchain` - the swapchain; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// What the device's queue still has to do is done first, the images it
/// was given to present shown. On a screen the screen's own buffer is shown
/// again, and the buffers made for the swapchain are freed.
///
/// CONTEXT:
/// - Waits: for the queue's work, and for the display's next frame where
///   the screen's own buffer is shown again.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The framebuffers and views made of its images go first: the images go
/// with it.
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
/// fb.DestroySwapchain(device, swapchain);
/// ```
pub fn DestroySwapchain(base: *FacetBase, device: *facet.Device, swapchain: ?*facet.Swapchain) void {
    _ = device;
    const made = _objects.of(Swapchain, swapchain orelse return);
    const sys = base.sys_base;
    if (made.device.has_queue) _queue.waitIdle(&made.device.queue, sys);
    const surface = made.surface;
    const live = surface.swapchain == made;
    surface.ops.unmake(surface, made.pictures[0..made.count], if (live) _swapchain.shownImage(made) else null);
    if (live) surface.swapchain = null;
    surface.swapchains -= 1;
    _objects.destroy(sys, made);
}
