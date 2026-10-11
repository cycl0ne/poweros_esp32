// SPDX-License-Identifier: MIT
//! OpenUSBPipe: a request filled in for one endpoint of a device.

const sdk = @import("sdk");
const exec = sdk.exec;
const usb = sdk.usb;
const usbhc = sdk.devices.usbhc;
const d = usb.descriptors;
const UsbBase = @import("../usb_base.zig").UsbBase;
const _bus = @import("../bus/_bus.zig");
const _pipe = @import("_pipe.zig");

/// Opens a pipe to one endpoint of a device: a request already filled in
/// for it.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenUSBPipe(base: *UsbBase, device: *usb.USBDevice, endpoint_address: u32, reply_port: *exec.MsgPort) ?*usb.USBPipe
/// ```
///
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// - `device` - the device, which the caller drives (a binding, or a
///   claimed interface).
/// - `endpoint_address` - the endpoint's bEndpointAddress, its number
///   with `USB_DIR_IN` for one that sends; 0 for the control endpoint.
/// - `reply_port` - where the request is replied.
///
/// RESULT:
/// The pipe, or null if the device has no such endpoint or there is no
/// memory.
///
/// BEHAVIOR:
/// The pipe's `io` is an `IOUsbHC` on the device's bus's controller, its
/// command set by the endpoint's type (`UHCMD_CONTROLXFER`,
/// `UHCMD_BULKXFER`, `UHCMD_INTXFER`), the device's address, speed and
/// hub, the endpoint, its packet size and its interval in milliseconds,
/// its data toggle at DATA0. The caller sets io_Data and io_Length - and
/// a control pipe's setup packet - and sends it with SendIO or DoIO, as
/// often as it likes; the toggle stays in it. An isochronous endpoint has
/// no pipe yet.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pipe is the caller's until CloseUSBPipe; nothing of it may be
/// outstanding then. When the device goes, its driver closes its pipes
/// in USBClassUnbind; a transfer outstanding meanwhile ends with
/// `UHIOERR_DETACHED` or another error.
///
/// NOTES:
/// One request per pipe: two transfers at once on one endpoint want two
/// pipes, and then the toggle is not theirs to share.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseUSBPipe`, `FindUSBEndpoint`, `ClearUSBStall`
///
/// EXAMPLES:
/// ```zig
/// const pipe = ub.OpenUSBPipe(device, in.endpoint_address, port) orelse return false;
/// pipe.io.std.data = &report;
/// pipe.io.std.length = report.len;
/// sys.SendIO(&pipe.io.std.req);
/// ```
pub fn OpenUSBPipe(base: *UsbBase, device: *usb.USBDevice, endpoint_address: u32, reply_port: *exec.MsgPort) ?*usb.USBPipe {
    const sys = base.sys_base;
    const kept = _bus.deviceOf(device);
    var io = _bus.controlRequest(kept, reply_port);
    io.nak_timeout = 0;
    if (endpoint_address != 0) {
        const endpoint = _pipe.findEndpoint(kept, @truncate(endpoint_address)) orelse return null;
        io.endpoint = endpoint.endpoint_address;
        io.max_packet = @max(endpoint.max_packet_size & 0x7FF, 1);
        io.std.req.command = switch (endpoint.attributes & d.USB_ENDPOINT_XFERTYPE_MASK) {
            d.USB_ENDPOINT_XFER_BULK => usbhc.UHCMD_BULKXFER,
            d.USB_ENDPOINT_XFER_INT => usbhc.UHCMD_INTXFER,
            d.USB_ENDPOINT_XFER_CONTROL => usbhc.UHCMD_CONTROLXFER,
            else => return null,
        };
        io.interval = intervalMs(device.speed, endpoint.interval);
    }
    const memory = sys.AllocMem(@sizeOf(usb.USBPipe), exec.MEMF_CLEAR) orelse return null;
    const pipe: *usb.USBPipe = @ptrCast(@alignCast(memory));
    pipe.* = .{ .io = io, .device = device };
    return pipe;
}

/// bInterval as milliseconds: frames at full and low speed, 2^(n-1)
/// microframes at high speed; never less than one.
fn intervalMs(speed: u8, interval: u8) u16 {
    if (speed != usbhc.USB_SPEED_HIGH) return @max(interval, 1);
    const exponent: u5 = @intCast(@min(@max(interval, 1), 16) - 1);
    const microframes = @as(u32, 1) << exponent;
    return @intCast(@max(microframes / 8, 1));
}
