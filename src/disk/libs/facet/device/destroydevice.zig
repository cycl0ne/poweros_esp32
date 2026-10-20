// SPDX-License-Identifier: MIT
//! DestroyDevice: a device given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("_device.zig").Device;
const _queue = @import("../queue/_queue.zig");

/// The device given back, and its queue's task ended.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroyDevice(base: *FacetBase, device: ?*facet.Device) void
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `device` - a device CreateDevice made, or null, which does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Everything made from the device has to be destroyed or freed first,
/// and its queue idle (DeviceWaitIdle). Memory not freed is left as it
/// is, and said so on the debug output.
///
/// CONTEXT:
/// - Waits: for the queue's task to end.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The device is gone, and its queue with it.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateDevice`, `DestroyInstance`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroyDevice(device);
/// ```
pub fn DestroyDevice(base: *FacetBase, device: ?*facet.Device) void {
    const made = _objects.of(Device, device orelse return);
    const sys = base.sys_base;
    if (made.allocations != 0) {
        sdk.exec.kprintf(sys, "facet.library: a device destroyed with %ld blocks of memory not freed\n", .{@as(i64, made.allocations)});
    }
    if (!_queue.stop(&made.queue, sys)) {
        sdk.exec.kprintf(sys, "facet.library: no signal to end a device's queue with, the device kept\n", .{});
        return;
    }
    made.instance.devices -= 1;
    _objects.destroy(sys, made);
}
