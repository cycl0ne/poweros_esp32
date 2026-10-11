// SPDX-License-Identifier: MIT
//! NextUSBDescriptor: the walk along a device's configuration.

const sdk = @import("sdk");
const usb = sdk.usb;
const UsbBase = @import("../usb_base.zig").UsbBase;
const _bus = @import("../bus/_bus.zig");

/// Finds the next descriptor of a kind in a device's configuration.
///
/// SYNOPSIS:
/// ```zig
/// fn NextUSBDescriptor(base: *UsbBase, device: *usb.USBDevice, previous: ?*const usb.DescriptorHeader, descriptor_type: u32) ?*const usb.DescriptorHeader
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `device` - a device on the list, or the one a driver was bound to.
/// - `previous` - a descriptor this call answered for the device, or null
///   to start after the configuration's own.
/// - `descriptor_type` - `USB_DT_*`, or 0 for any.
///
/// RESULT:
/// The descriptor, in the device's configuration as it came; null past
/// the last, or for a device with no configuration.
///
/// BEHAVIOR:
/// The descriptors are walked by their lengths, as the device sent them:
/// an interface's endpoints and its class's own descriptors follow it.
/// A length that would run past the end ends the walk.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none; the device must not go meanwhile - hold the list, or
///   be its driver.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The descriptor stays the device's: it lives as long as the device.
///
/// NOTES:
/// A descriptor is not aligned: its fields wider than a byte are read
/// through the SDK's structures, whose fields are `align(1)`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindUSBInterface`, `FindUSBEndpoint`
///
/// EXAMPLES:
/// ```zig
/// var at = ub.NextUSBDescriptor(device, null, usb.descriptors.USB_DT_HID);
/// if (at) |hid| report_length = readReportLength(hid);
/// ```
pub fn NextUSBDescriptor(_: *UsbBase, device: *usb.USBDevice, previous: ?*const usb.DescriptorHeader, descriptor_type: u32) ?*const usb.DescriptorHeader {
    const kept = _bus.deviceOf(device);
    const config = device.config orelse return null;
    const offset: u32 = if (previous) |was| @intCast(@intFromPtr(was) - @intFromPtr(config)) else 0;
    const found = _bus.nextDescriptor(kept, offset, @truncate(descriptor_type)) orelse return null;
    return @ptrCast(config + found);
}
