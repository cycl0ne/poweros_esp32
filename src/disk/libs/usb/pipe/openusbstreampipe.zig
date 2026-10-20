// SPDX-License-Identifier: MIT
//! OpenUSBStreamPipe: a request filled in for one stream of a SuperSpeed
//! bulk endpoint.

const sdk = @import("sdk");
const exec = sdk.exec;
const usb = sdk.usb;
const usbhc = sdk.devices.usbhc;
const usb_base = @import("../usb_base.zig");
const UsbBase = usb_base.UsbBase;
const _bus = @import("../bus/_bus.zig");
const _pipe = @import("_pipe.zig");

/// Opens a pipe to one stream of a SuperSpeed bulk endpoint.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenUSBStreamPipe(base: *UsbBase, device: *usb.USBDevice, endpoint_address: u32, stream: u32, reply_port: *exec.MsgPort) ?*usb.USBPipe
/// ```
///
/// SINCE: 1.10. LVO -84.
///
/// INPUTS:
/// - `device` - the device, which the caller drives (a binding, or a
///   claimed interface).
/// - `endpoint_address` - the bulk endpoint's bEndpointAddress, with
///   `USB_DIR_IN` for one that sends.
/// - `stream` - the stream's ID, from 1 to the endpoint's streams.
/// - `reply_port` - where the request is replied.
///
/// RESULT:
/// The pipe, or null if the device is not at SuperSpeed, it has no such
/// endpoint, the endpoint is not a bulk one with streams, the stream is
/// not among them, or there is no memory.
///
/// BEHAVIOR:
/// The pipe is the one `OpenUSBPipe` opens for the endpoint, its request
/// naming the endpoint's streams (`streams`: the 2^MaxStreams its
/// companion descriptor offers, at most 16) and the one it goes on
/// (`stream`). Where settings of the device have bulk endpoints at the
/// same address - one without streams, one with, as a disk's Bulk-Only
/// and UAS settings may - the pipe is the one with streams, its packet
/// size and bursts that endpoint's.
///
/// Each stream is a queue of its own on the endpoint: a transfer on one
/// waits only for those before it on the same, and the device says which
/// stream it moves data on next - so a pipe per stream can each have a
/// transfer out at once.
///
/// A controller without streams answers the pipe's first transfer
/// UHIOERR_HOSTERROR, as does one whose stream arrays hold fewer than
/// the stream named; xhci.device's hold 16 where the controller does.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pipe is the caller's until CloseUSBPipe; nothing of it may be
/// outstanding then.
///
/// NOTES:
/// Every transfer on an endpoint with streams goes on a stream: a pipe
/// from `OpenUSBPipe` on the same endpoint has the controller add the
/// endpoint afresh without them, and what was on its streams ends with
/// UHIOERR_HOSTERROR. ClearUSBStall takes any of the endpoint's pipes.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenUSBPipe`, `CloseUSBPipe`, `ClearUSBStall`
///
/// EXAMPLES:
/// ```zig
/// const status = ub.OpenUSBStreamPipe(device, status_in, tag, port) orelse return false;
/// status.io.std.data = &sense;
/// status.io.std.length = sense.len;
/// sys.SendIO(&status.io.std.req);
/// ```
pub fn OpenUSBStreamPipe(base: *UsbBase, device: *usb.USBDevice, endpoint_address: u32, stream: u32, reply_port: *exec.MsgPort) ?*usb.USBPipe {
    const kept = _bus.deviceOf(device);
    const endpoint = _pipe.findStreamEndpoint(kept, @truncate(endpoint_address)) orelse return null;
    const streams = _pipe.streamsOf(kept, endpoint);
    if (stream == 0 or stream > streams) return null;
    const pipe = usb_base.interface(base).OpenUSBPipe(device, endpoint_address, reply_port) orelse return null;
    // The endpoint with streams, whichever OpenUSBPipe found first.
    pipe.io.std.req.command = usbhc.UHCMD_BULKXFER;
    pipe.io.max_packet = @max(endpoint.max_packet_size & 0x7FF, 1);
    pipe.io.burst = _pipe.burstsOf(kept, endpoint).burst;
    pipe.io.streams = streams;
    pipe.io.stream = @intCast(stream);
    return pipe;
}
