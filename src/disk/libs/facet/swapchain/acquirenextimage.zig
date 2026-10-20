// SPDX-License-Identifier: MIT
//! AcquireNextImage: the next image to draw into.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _swapchain = @import("_swapchain.zig");
const Swapchain = _swapchain.Swapchain;
const _sync = @import("../sync/_sync.zig");

/// An image of the swapchain to draw into, its number written to `index`.
///
/// SYNOPSIS:
/// ```zig
/// fn AcquireNextImage(base: *FacetBase, device: *facet.Device, swapchain: *facet.Swapchain, timeout: u64, semaphore: ?*facet.Semaphore, fence: ?*facet.Fence, index: *u32) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -356.
///
/// INPUTS:
/// - `device` - the device it was made with.
/// - `swapchain` - the swapchain.
/// - `timeout` - the nanoseconds to wait for one at most; WAIT_FOREVER_NS
///   waits as long as it takes, 0 not at all.
/// - `semaphore`, `fence` - signalled when the image can be drawn into, or
///   null.
/// - `index` - the image's number, as GetSwapchainImages lists them.
///
/// RESULT:
/// `success`; `timeout`, or `not_ready` with a timeout of 0, when none
/// came free in time, or none will - each held by the program, or shown
/// with nothing presented after it; `error_out_of_date` when the surface's
/// size or format has changed, or the swapchain has been handed on;
/// `error_surface_lost` when the window the surface is over has closed.
///
/// BEHAVIOR:
/// An image is handed out when the display no longer reads it: the one
/// shown comes free when the display has taken up the next presented. So
/// the semaphore and the fence are signalled as the call returns. A
/// swapchain of one image hands out the image shown, drawn while it is seen.
///
/// CONTEXT:
/// - Waits: for an image to come free, at most `timeout`.
/// - Interrupts: no.
/// - Locks: no spinlock may be held; on a window's surface, no layer's
///   lock either - its window is found under the screens' semaphore.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The image is the program's until it is presented.
///
/// NOTES:
/// With two images, a frame is drawn into one while the other is shown,
/// and the next acquire waits for the display to take up the frame
/// presented: this is what holds a program to the display's rate.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `QueuePresent`, `GetSwapchainImages`
///
/// EXAMPLES:
/// ```zig
/// var index: u32 = 0;
/// switch (fb.AcquireNextImage(device, swapchain.?, facet.WAIT_FOREVER_NS, acquired.?, null, &index)) {
///     .success => {},
///     .error_out_of_date => return remake(),
///     .error_surface_lost => return error.WindowClosed,
///     else => return error.NoImage,
/// }
/// ```
pub fn AcquireNextImage(base: *FacetBase, device: *facet.Device, swapchain: *facet.Swapchain, timeout: u64, semaphore: ?*facet.Semaphore, fence: ?*facet.Fence, index: *u32) facet.Result {
    _ = device;
    const made = _objects.of(Swapchain, swapchain);
    const sys = base.sys_base;
    switch (_swapchain.acquire(made, sys, _sync.microseconds(timeout))) {
        .image => |got| {
            if (semaphore) |handle| sys.SignalWaitable(&_objects.of(_sync.Semaphore, handle).waitable);
            if (fence) |handle| sys.SignalWaitable(&_objects.of(_sync.Fence, handle).waitable);
            index.* = got;
            return .success;
        },
        .none, .timeout => return if (timeout == 0) .not_ready else .timeout,
        .out_of_date => return .error_out_of_date,
        .lost => return .error_surface_lost,
    }
}
