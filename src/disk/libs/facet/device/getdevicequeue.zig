// SPDX-License-Identifier: MIT
//! GetDeviceQueue: a device's queue.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("_device.zig").Device;

/// A queue the device was made with.
///
/// SYNOPSIS:
/// ```zig
/// fn GetDeviceQueue(base: *FacetBase, device: *facet.Device, family: u32, index: u32, queue: *?*facet.Queue) void
/// ```
///
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// - `device` - the device.
/// - `family` - the queue's family: 0.
/// - `index` - which of the family's queues: 0.
/// - `queue` - where the queue is written; null for one the device was
///   not made with.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The same queue each time it is asked for.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The queue is the device's, and goes with it.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateDevice`, `QueueSubmit`
///
/// EXAMPLES:
/// ```zig
/// var queue: ?*facet.Queue = null;
/// fb.GetDeviceQueue(device, 0, 0, &queue);
/// ```
pub fn GetDeviceQueue(base: *FacetBase, device: *facet.Device, family: u32, index: u32, queue: *?*facet.Queue) void {
    _ = base;
    const made = _objects.of(Device, device);
    queue.* = if (made.has_queue and family == 0 and index == 0) _objects.handle(facet.Queue, &made.queue) else null;
}
