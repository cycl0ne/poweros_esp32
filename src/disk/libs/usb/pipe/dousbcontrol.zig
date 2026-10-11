// SPDX-License-Identifier: MIT
//! DoUSBControl: a control transfer on a device's endpoint 0.

const sdk = @import("sdk");
const usb = sdk.usb;
const UsbBase = @import("../usb_base.zig").UsbBase;
const _bus = @import("../bus/_bus.zig");

/// Makes a control transfer on a device's endpoint 0, and waits for it.
///
/// SYNOPSIS:
/// ```zig
/// fn DoUSBControl(base: *UsbBase, device: *usb.USBDevice, setup: *const usb.SetupPacket, data: ?*anyopaque, actual: ?*u32) i32
/// ```
///
/// SINCE: 1.0. LVO -60.
///
/// INPUTS:
/// - `device` - the device.
/// - `setup` - the setup packet; its `length` is the data stage's bytes,
///   its `request_type` their direction.
/// - `data` - the data stage's bytes, `setup.length` of them; null when
///   there are none.
/// - `actual` - where the bytes moved go; null if not wanted.
///
/// RESULT:
/// 0, or the transfer's io_Error (`UHIOERR_STALL` for a request the
/// device refused, `UHIOERR_NAKTIMEOUT` for one it never answered in a
/// second, `UHIOERR_DETACHED` for a device that went).
///
/// BEHAVIOR:
/// The transfer is the caller's own request, on a port made for it: two
/// tasks may each make one on the same device at once, and the device
/// answers them in turn.
///
/// CONTEXT:
/// - Waits: yes, for the device.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `data` is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenUSBPipe`, `GetUSBString`
///
/// EXAMPLES:
/// ```zig
/// const idle = usb.SetupPacket{ .request_type = d.USB_TYPE_CLASS | d.USB_RECIP_INTERFACE,
///     .request = d.HID_REQ_SET_IDLE, .value = 0, .index = number, .length = 0 };
/// _ = ub.DoUSBControl(device, &idle, null, null);
/// ```
pub fn DoUSBControl(base: *UsbBase, device: *usb.USBDevice, setup: *const usb.SetupPacket, data: ?*anyopaque, actual: ?*u32) i32 {
    const sys = base.sys_base;
    const port = sys.CreateMsgPort() orelse return -1;
    defer sys.DeleteMsgPort(port);
    return _bus.controlOn(sys, _bus.deviceOf(device), port, setup.*, data, actual);
}
