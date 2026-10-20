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
/// The pipe, or null if the device has no such endpoint, it is an
/// isochronous one asking for packets more often than once a
/// millisecond, or there is no memory.
///
/// BEHAVIOR:
/// The pipe's `io` is an `IOUsbHC` on the device's bus's controller, its
/// command set by the endpoint's type (`UHCMD_CONTROLXFER`,
/// `UHCMD_BULKXFER`, `UHCMD_INTXFER`, `UHCMD_ISOXFER`), the device's
/// address, speed and hub, the endpoint, its packet size and its interval
/// in milliseconds, its data toggle at DATA0. The caller sets io_Data and
/// io_Length - and a control pipe's setup packet, an isochronous pipe's
/// `iso_packet` if its packets are smaller than the endpoint's, or its
/// `iso_list` for packets of their own lengths - and sends it with
/// SendIO or DoIO, as often as it likes; the toggle stays in it. An
/// isochronous transfer comes back with what became of its packets
/// (`iso_lost`, the list's `status`), the frame it started in and its
/// gap behind the one before (sdk/devices/usbhc.zig).
///
/// An isochronous endpoint's interval is 2^(bInterval - 1) frames or, at
/// high speed, microframes; it is taken only at a millisecond or more,
/// which every endpoint of a full-speed device is.
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
/// pipes, and then the toggle is not theirs to share. An isochronous
/// stream wants two or more, so the next is with the controller before
/// the last has played: each a pipe of its own on the endpoint (Since
/// 1.6).
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
        const kind = endpoint.attributes & d.USB_ENDPOINT_XFERTYPE_MASK;
        io.std.req.command = switch (kind) {
            d.USB_ENDPOINT_XFER_BULK => usbhc.UHCMD_BULKXFER,
            d.USB_ENDPOINT_XFER_INT => usbhc.UHCMD_INTXFER,
            d.USB_ENDPOINT_XFER_CONTROL => usbhc.UHCMD_CONTROLXFER,
            else => usbhc.UHCMD_ISOXFER,
        };
        if (kind == d.USB_ENDPOINT_XFER_ISOC) {
            io.interval = isoIntervalMs(device.speed, endpoint.interval) orelse return null;
            io.iso_packet = io.max_packet;
        } else {
            io.interval = intervalMs(device.speed, endpoint.interval);
        }
    }
    const memory = sys.AllocMem(@sizeOf(usb.USBPipe), exec.MEMF_CLEAR) orelse return null;
    const pipe: *usb.USBPipe = @ptrCast(@alignCast(memory));
    pipe.* = .{ .io = io, .device = device };
    return pipe;
}

/// Whether a speed counts its intervals in microframes: high speed and
/// SuperSpeed.
fn inMicroframes(speed: u8) bool {
    return speed == usbhc.USB_SPEED_HIGH or speed == usbhc.USB_SPEED_SUPER;
}

/// An isochronous endpoint's bInterval as milliseconds: 2^(n-1) frames,
/// or at high speed and SuperSpeed microframes; null under a millisecond.
fn isoIntervalMs(speed: u8, interval: u8) ?u16 {
    const exponent: u5 = @intCast(@min(@max(interval, 1), 16) - 1);
    const units = @as(u32, 1) << exponent;
    if (!inMicroframes(speed)) return @intCast(@min(units, 0x8000));
    if (units < 8) return null;
    return @intCast(units / 8);
}

/// bInterval as milliseconds: frames at full and low speed, 2^(n-1)
/// microframes at high speed and SuperSpeed; never less than one.
fn intervalMs(speed: u8, interval: u8) u16 {
    if (!inMicroframes(speed)) return @max(interval, 1);
    const exponent: u5 = @intCast(@min(@max(interval, 1), 16) - 1);
    const microframes = @as(u32, 1) << exponent;
    return @intCast(@max(microframes / 8, 1));
}
