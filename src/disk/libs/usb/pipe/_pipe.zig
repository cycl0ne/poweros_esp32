// SPDX-License-Identifier: MIT
//! What the pipe calls share: an endpoint's descriptor found by its
//! address in a device's configuration, and what it moves an interval
//! besides its packet size.

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
            const config = device.public.config orelse return .{};
            const next = @intFromPtr(endpoint) - @intFromPtr(config) + endpoint.length;
            if (next + 6 > device.public.config_length) return .{};
            const companion = config[next..][0..6];
            if (companion[0] < 6 or companion[1] != d.USB_DT_SS_ENDPOINT_COMP) return .{};
            return .{
                .burst = @min(companion[2], 15),
                .mult = if (kind == d.USB_ENDPOINT_XFER_ISOC) @min(companion[3] & 3, 2) else 0,
                .interval_bytes = if (periodic) @as(u16, companion[4]) | @as(u16, companion[5]) << 8 else 0,
            };
        },
        else => return .{},
    }
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
