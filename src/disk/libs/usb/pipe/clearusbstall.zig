// SPDX-License-Identifier: MIT
//! ClearUSBStall: an endpoint's halt taken away.

const sdk = @import("sdk");
const usb = sdk.usb;
const d = usb.descriptors;
const UsbBase = @import("../usb_base.zig").UsbBase;
const _bus = @import("../bus/_bus.zig");

/// Clears a stalled endpoint's halt, and its data toggle with it.
///
/// SYNOPSIS:
/// ```zig
/// fn ClearUSBStall(base: *UsbBase, pipe: *usb.USBPipe) i32
/// ```
///
/// SINCE: 1.0. LVO -64.
///
/// INPUTS:
/// - `pipe` - the endpoint's pipe, with nothing outstanding.
///
/// RESULT:
/// 0, or the control transfer's io_Error.
///
/// BEHAVIOR:
/// CLEAR_FEATURE(ENDPOINT_HALT) to the endpoint, and the pipe's toggle
/// back to DATA0, which is where the device's goes too. A control pipe
/// has no halt to clear: 0 at once.
///
/// CONTEXT:
/// - Waits: yes, for the device.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenUSBPipe`, `DoUSBControl`
///
/// EXAMPLES:
/// ```zig
/// if (pipe.io.std.req.err == usbhc.UHIOERR_STALL) _ = ub.ClearUSBStall(pipe);
/// ```
pub fn ClearUSBStall(base: *UsbBase, pipe: *usb.USBPipe) i32 {
    const sys = base.sys_base;
    if (pipe.io.endpoint & d.USB_ENDPOINT_NUMBER_MASK == 0) return 0;
    const device = pipe.device orelse return -1;
    const port = sys.CreateMsgPort() orelse return -1;
    defer sys.DeleteMsgPort(port);
    const setup = usb.SetupPacket{
        .request_type = d.USB_DIR_OUT | d.USB_RECIP_ENDPOINT,
        .request = d.USB_REQ_CLEAR_FEATURE,
        .value = d.USB_FEATURE_ENDPOINT_HALT,
        .index = pipe.io.endpoint,
        .length = 0,
    };
    const err = _bus.controlOn(sys, _bus.deviceOf(device), port, setup, null, null);
    pipe.io.toggle = 0;
    return err;
}
