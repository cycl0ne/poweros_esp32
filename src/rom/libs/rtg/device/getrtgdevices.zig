// SPDX-License-Identifier: MPL-2.0
//! GetRtgDevices: Copy out the devices on the list.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _device = @import("_device.zig");

/// Copies out the devices on the library's list.
///
/// SYNOPSIS:
/// ```zig
/// fn GetRtgDevices(rb: *RtgBase, into: ?[*]rtg.RtgDeviceInfo, count: u32) u32
/// ```
///
/// SINCE: 1.18. LVO -216.
///
/// INPUTS:
/// - `into` - where the devices go, or null to ask how many there are.
/// - `count` - how many `into` has room for.
///
/// RESULT:
/// How many devices there are, which may be more than were copied.
///
/// BEHAVIOR:
/// Up to `count` devices are copied, in the order they were found: the
/// board's panel parts, the display functions on PCI, then the ones made
/// by `AddRtgDevice`. Each says its name, what the hardware is called,
/// what it is - its kind, its chip and bus, a function's vendor, device
/// and class - the driver that has it, how many boards that made of it,
/// and for the firmware's framebuffer the device it lies behind. The
/// machine's own devices are on the list from the first
/// `BindRtgDrivers`; before it the answer is those that were added.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the device list - through a
///   bind, which lasts as long as a driver's bring-up.
/// - Interrupts: no.
/// - Locks: takes the device list's lock. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated: the copies are the caller's, and hold no pointer
/// into the library.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetRtgDrivers`, `BindRtgDrivers`, `NextBoard`
///
/// EXAMPLES:
/// ```zig
/// var found: [8]rtg.RtgDeviceInfo = undefined;
/// const there = rb.GetRtgDevices(&found, found.len);
/// for (found[0..@min(there, found.len)]) |*device| list(device);
/// ```
pub fn GetRtgDevices(rb: *RtgBase, into: ?[*]rtg.RtgDeviceInfo, count: u32) u32 {
    const sys = rb.sys_base;
    const ub = rb.utility_base;
    sys.ObtainSemaphore(&rb.device_lock);
    defer sys.ReleaseSemaphore(&rb.device_lock);
    var there: u32 = 0;
    var node = rb.devices.first();
    while (node) |one| : (node = one.next()) {
        const device = _device.deviceOf(one);
        const private = _device.privateOf(device);
        if (into != null and there < count) {
            const info = &into.?[there];
            info.* = .{
                .kind = device.kind,
                .flags = device.flags,
                .chip = device.chip,
                .bus = device.bus,
            };
            _ = ub.Strlcpy(&info.name, info.name.len, device.node.name.?);
            if (private.chip_name) |called| _ = ub.Strlcpy(&info.chip_name, info.chip_name.len, called);
            if (device.driver) |driver| _ = ub.Strlcpy(&info.driver, info.driver.len, driver.spec.name);
            if (device.behind) |around| _ = ub.Strlcpy(&info.behind, info.behind.len, around.node.name.?);
            if (device.pci) |function| {
                info.vendor = function.vendor_id;
                info.device = function.device_id;
                info.class_code = function.class_code;
            }
            var link = private.boards.first();
            while (link) |board| : (link = board.next()) info.boards += 1;
        }
        there += 1;
    }
    return there;
}
