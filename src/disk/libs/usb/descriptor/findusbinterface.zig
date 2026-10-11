// SPDX-License-Identifier: MIT
//! FindUSBInterface: an interface of a device by its class.

const sdk = @import("sdk");
const usb = sdk.usb;
const d = usb.descriptors;
const UsbBase = @import("../usb_base.zig").UsbBase;
const _bus = @import("../bus/_bus.zig");

/// Finds a device's next interface of a class, subclass and protocol.
///
/// SYNOPSIS:
/// ```zig
/// fn FindUSBInterface(base: *UsbBase, device: *usb.USBDevice, previous: ?*const usb.InterfaceDescriptor, class: i32, subclass: i32, protocol: i32) ?*const usb.InterfaceDescriptor
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `device` - a device on the list, or the one a driver was bound to.
/// - `previous` - an interface this call answered, or null for the first.
/// - `class`, `subclass`, `protocol` - what the interface must be; -1
///   for any.
///
/// RESULT:
/// The interface's descriptor in the device's configuration, or null.
///
/// BEHAVIOR:
/// Every setting of every interface is looked at, alternate settings
/// too, in the order the device sent them.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none; the device must not go meanwhile.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The descriptor stays the device's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NextUSBDescriptor`, `FindUSBEndpoint`
///
/// EXAMPLES:
/// ```zig
/// const hid = ub.FindUSBInterface(device, null, d.USB_CLASS_HID, -1, -1) orelse return;
/// ```
pub fn FindUSBInterface(_: *UsbBase, device: *usb.USBDevice, previous: ?*const usb.InterfaceDescriptor, class: i32, subclass: i32, protocol: i32) ?*const usb.InterfaceDescriptor {
    const kept = _bus.deviceOf(device);
    const config = device.config orelse return null;
    var offset: u32 = if (previous) |was| @intCast(@intFromPtr(was) - @intFromPtr(config)) else 0;
    while (_bus.nextDescriptor(kept, offset, d.USB_DT_INTERFACE)) |found| : (offset = found) {
        const interface: *const usb.InterfaceDescriptor = @ptrCast(config + found);
        if (class >= 0 and interface.interface_class != class) continue;
        if (subclass >= 0 and interface.interface_subclass != subclass) continue;
        if (protocol >= 0 and interface.interface_protocol != protocol) continue;
        return interface;
    }
    return null;
}
