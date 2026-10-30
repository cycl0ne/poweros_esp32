// SPDX-License-Identifier: MIT
//! QueueWaitIdle: waiting for a queue to be done.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _queue = @import("_queue.zig");

/// Wait until the queue has done all it was given.
///
/// SYNOPSIS:
/// ```zig
/// fn QueueWaitIdle(base: *FacetBase, queue: *facet.Queue) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -168.
///
/// INPUTS:
/// - `queue` - the queue.
///
/// RESULT:
/// `success`; `error_device_lost` once the device is lost.
///
/// BEHAVIOR:
/// Returns once every batch submitted before the call has been played and
/// its fence and semaphores signalled.
///
/// CONTEXT:
/// - Waits: yes, on the queue's idle waitable.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// None.
///
/// NOTES:
/// A fence waits for one submission; this for all.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DeviceWaitIdle`, `WaitForFences`
///
/// EXAMPLES:
/// ```zig
/// _ = fb.QueueWaitIdle(queue.?);
/// ```
pub fn QueueWaitIdle(base: *FacetBase, queue: *facet.Queue) facet.Result {
    const made = _objects.of(_queue.Queue, queue);
    _queue.waitIdle(made, base.sys_base);
    return if (made.device.isLost()) .error_device_lost else .success;
}
