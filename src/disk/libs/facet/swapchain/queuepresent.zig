// SPDX-License-Identifier: MIT
//! QueuePresent: images shown.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _swapchain = @import("_swapchain.zig");
const Swapchain = _swapchain.Swapchain;
const _queue = @import("../queue/_queue.zig");
const Semaphore = @import("../sync/_sync.zig").Semaphore;

/// Images handed to the queue to be shown, once the semaphores are
/// signalled.
///
/// SYNOPSIS:
/// ```zig
/// fn QueuePresent(base: *FacetBase, queue: *facet.Queue, info: *const facet.PresentInfo) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -360.
///
/// INPUTS:
/// - `queue` - the queue that shows them: the device's.
/// - `info` - the semaphores waited for, and an image of each swapchain,
///   acquired, with a place for what came of each where `results` is not
///   null.
///
/// RESULT:
/// `success`; `error_out_of_date` when a swapchain's surface has changed,
/// or an image was not one the program held - that image is not shown;
/// `error_out_of_host_memory`. The worst of them, and each in `results`.
///
/// BEHAVIOR:
/// The images go on the queue after the work submitted before: when the
/// queue's task comes to them it waits for the semaphores, then shows each,
/// returning when the display has taken it up at the start of a frame. The
/// image shown before it then comes free for AcquireNextImage. The call
/// itself returns at once.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The images are the swapchain's again: the program has them no more.
///
/// NOTES:
/// The queue's task waits for the display while it shows an image: work
/// submitted after the present waits behind it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AcquireNextImage`, `QueueSubmit`
///
/// EXAMPLES:
/// ```zig
/// const shown = fb.QueuePresent(queue.?, &.{
///     .wait_semaphore_count = 1,
///     .wait_semaphores = @ptrCast(&rendered),
///     .swapchains = @ptrCast(&swapchain),
///     .image_indices = @ptrCast(&index),
/// });
/// ```
pub fn QueuePresent(base: *FacetBase, queue: *facet.Queue, info: *const facet.PresentInfo) facet.Result {
    const made = _objects.of(_queue.Queue, queue);
    const sys = base.sys_base;
    const waits: []const *Semaphore = if (info.wait_semaphores) |given| @as([*]const *Semaphore, @ptrCast(given))[0..info.wait_semaphore_count] else &.{};
    var presents: [_swapchain.max_presents]_queue.Present = undefined;
    var taken: usize = 0;
    var worst: facet.Result = .success;
    for (info.swapchains[0..info.swapchain_count], info.image_indices[0..info.swapchain_count], 0..) |handle, index, k| {
        const chain = _objects.of(Swapchain, handle);
        const result: facet.Result = result: {
            if (taken == presents.len or !_swapchain.current(chain)) {
                _swapchain.giveBack(chain, sys, index);
                break :result .error_out_of_date;
            }
            if (!_swapchain.hand(chain, sys, index)) break :result .error_out_of_date;
            presents[taken] = .{ .swapchain = chain, .index = index };
            taken += 1;
            break :result .success;
        };
        if (info.results) |results| results[k] = result;
        if (result != .success) worst = result;
    }
    // The semaphores are waited for whether anything is shown or not.
    if (!_queue.present(made, sys, waits, presents[0..taken], base.inline_queues)) {
        for (presents[0..taken]) |each| _swapchain.unhand(each.swapchain, sys, each.index);
        return .error_out_of_host_memory;
    }
    return worst;
}
