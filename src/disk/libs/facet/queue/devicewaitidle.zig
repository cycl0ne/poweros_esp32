// SPDX-License-Identifier: MIT
//! DeviceWaitIdle: waiting for a device to be done.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _queue = @import("_queue.zig");
const Device = @import("../device/_device.zig").Device;

/// Wait until every queue of the device has done all it was given.
///
/// SYNOPSIS:
/// ```zig
/// fn DeviceWaitIdle(base: *FacetBase, device: *facet.Device) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -172.
///
/// INPUTS:
/// - `device` - the device.
///
/// RESULT:
/// `success`; `error_device_lost` once the device is lost. The queue is idle
/// either way.
///
/// BEHAVIOR:
/// QueueWaitIdle on its queue; at once for a device without one.
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
/// What a program does before it destroys what its work uses, and the device.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `QueueWaitIdle`, `DestroyDevice`
///
/// EXAMPLES:
/// ```zig
/// _ = fb.DeviceWaitIdle(device);
/// fb.DestroyDevice(device);
/// ```
pub fn DeviceWaitIdle(base: *FacetBase, device: *facet.Device) facet.Result {
    const made = _objects.of(Device, device);
    _queue.waitIdle(&made.queue, base.sys_base);
    return if (made.isLost()) .error_device_lost else .success;
}
