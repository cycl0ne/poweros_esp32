// SPDX-License-Identifier: MIT
//! GetUSBString: one of a device's strings, as Latin-1.

const sdk = @import("sdk");
const usb = sdk.usb;
const UsbBase = @import("../usb_base.zig").UsbBase;
const _bus = @import("../bus/_bus.zig");

/// Reads one of a device's strings, as Latin-1.
///
/// SYNOPSIS:
/// ```zig
/// fn GetUSBString(base: *UsbBase, device: *usb.USBDevice, index: u32, buffer: [*]u8, size: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `device` - the device.
/// - `index` - the string's index, as a descriptor gives it (1 to 255).
/// - `buffer`, `size` - where it goes, NUL-ended; at least 1 byte.
///
/// RESULT:
/// Its length, without the NUL; -1 if the device has no such string, did
/// not answer, or `size` is 0.
///
/// BEHAVIOR:
/// The device is asked in the language it listed first. A character
/// Latin-1 has not is `?`; what does not fit is cut off.
///
/// CONTEXT:
/// - Waits: yes, for the device to answer: a control transfer.
/// - Interrupts: no.
/// - Locks: none may be held; the device must not go meanwhile.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffer is the caller's.
///
/// NOTES:
/// The device's manufacturer, product and serial number are read when it
/// is set up and kept in its `USBDevice`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NextUSBDescriptor`
///
/// EXAMPLES:
/// ```zig
/// var name: [64]u8 = undefined;
/// if (ub.GetUSBString(device, interface.interface_string, &name, name.len) > 0) show(&name);
/// ```
pub fn GetUSBString(base: *UsbBase, device: *usb.USBDevice, index: u32, buffer: [*]u8, size: u32) i32 {
    const sys = base.sys_base;
    if (size == 0 or index == 0 or index > 255) return -1;
    const port = sys.CreateMsgPort() orelse return -1;
    defer sys.DeleteMsgPort(port);
    const length = _bus.readString(sys, _bus.deviceOf(device), port, @intCast(index), buffer[0..size]) orelse return -1;
    return @intCast(length);
}
