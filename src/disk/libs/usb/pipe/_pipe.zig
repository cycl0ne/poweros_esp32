// SPDX-License-Identifier: MIT
//! What the pipe calls share: an endpoint's descriptor found by its
//! address in a device's configuration, what it moves an interval
//! besides its packet size, and a SuperSpeed bulk endpoint's streams.

const sdk = @import("sdk");
const usb = sdk.usb;
const usbhc = sdk.devices.usbhc;
const d = usb.descriptors;
const _bus = @import("../bus/_bus.zig");

/// What an endpoint moves besides a packet at a time, as a request says
/// it (sdk/devices/usbhc.zig): the wire packets of a burst less one, a
/// SuperSpeed isochronous endpoint's bursts an interval less one, a
/// periodic endpoint's bytes an interval.
pub const Bursts = struct {
    burst: u8 = 0,
    mult: u8 = 0,
    interval_bytes: u16 = 0,
};

/// `endpoint`'s bursts on `device`: at SuperSpeed from the companion
/// descriptor that follows it, at high speed a periodic endpoint's from
/// wMaxPacketSize bits 12:11; none for a full- or low-speed device.
pub fn burstsOf(device: *const _bus.Device, endpoint: *const usb.EndpointDescriptor) Bursts {
    const kind = endpoint.attributes & d.USB_ENDPOINT_XFERTYPE_MASK;
    const periodic = kind == d.USB_ENDPOINT_XFER_INT or kind == d.USB_ENDPOINT_XFER_ISOC;
    const packet: u16 = endpoint.max_packet_size & 0x7FF;
    switch (device.public.speed) {
        usbhc.USB_SPEED_HIGH => {
            if (!periodic) return .{};
            const more: u8 = @truncate(@min((endpoint.max_packet_size >> 11) & 3, 2));
            return .{ .burst = more, .interval_bytes = packet * (more + 1) };
        },
        usbhc.USB_SPEED_SUPER => {
            const companion = companionOf(device, endpoint) orelse return .{};
            return .{
                .burst = @min(companion[2], 15),
                .mult = if (kind == d.USB_ENDPOINT_XFER_ISOC) @min(companion[3] & 3, 2) else 0,
                .interval_bytes = if (periodic) @as(u16, companion[4]) | @as(u16, companion[5]) << 8 else 0,
            };
        },
        else => return .{},
    }
}

/// The most streams a stream pipe names: the IDs a bulk endpoint's
/// streams are given, of the 2^MaxStreams its companion offers.
pub const max_streams = 16;

/// A SuperSpeed bulk endpoint's streams: the 2^n its companion's
/// bmAttributes offer, at most `max_streams`; 0 for an endpoint without
/// them, or of a device below SuperSpeed.
pub fn streamsOf(device: *const _bus.Device, endpoint: *const usb.EndpointDescriptor) u16 {
    if (device.public.speed != usbhc.USB_SPEED_SUPER) return 0;
    if (endpoint.attributes & d.USB_ENDPOINT_XFERTYPE_MASK != d.USB_ENDPOINT_XFER_BULK) return 0;
    const companion = companionOf(device, endpoint) orelse return 0;
    const exponent = companion[3] & 0x1F;
    if (exponent == 0) return 0;
    return if (exponent >= 4) max_streams else @as(u16, 1) << @intCast(exponent);
}

/// The SuperSpeed endpoint companion that follows `endpoint` in the
/// device's configuration, or null.
fn companionOf(device: *const _bus.Device, endpoint: *const usb.EndpointDescriptor) ?*const [6]u8 {
    const config = device.public.config orelse return null;
    const next = @intFromPtr(endpoint) - @intFromPtr(config) + endpoint.length;
    if (next + 6 > device.public.config_length) return null;
    const companion = config[next..][0..6];
    if (companion[0] < 6 or companion[1] != d.USB_DT_SS_ENDPOINT_COMP) return null;
    return companion;
}

/// The descriptor of the bulk endpoint at `address` that has streams, in
/// any setting of any interface of the device - one setting may have the
/// address without them, another with - or null.
pub fn findStreamEndpoint(device: *const _bus.Device, address: u8) ?*const usb.EndpointDescriptor {
    const config = device.public.config orelse return null;
    var offset: u32 = 0;
    while (_bus.nextDescriptor(device, offset, d.USB_DT_ENDPOINT)) |found| : (offset = found) {
        const endpoint: *const usb.EndpointDescriptor = @ptrCast(config + found);
        if (endpoint.endpoint_address == address and streamsOf(device, endpoint) != 0) return endpoint;
    }
    return null;
}

/// The descriptor of the endpoint at `address` in any interface of the
/// device, or null.
pub fn findEndpoint(device: *const _bus.Device, address: u8) ?*const usb.EndpointDescriptor {
    const config = device.public.config orelse return null;
    var offset: u32 = 0;
    while (_bus.nextDescriptor(device, offset, d.USB_DT_ENDPOINT)) |found| : (offset = found) {
        const endpoint: *const usb.EndpointDescriptor = @ptrCast(config + found);
        if (endpoint.endpoint_address == address) return endpoint;
    }
    return null;
}
