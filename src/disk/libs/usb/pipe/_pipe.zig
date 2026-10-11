// SPDX-License-Identifier: MIT
//! What the pipe calls share: an endpoint's descriptor found by its
//! address in a device's configuration.

const sdk = @import("sdk");
const usb = sdk.usb;
const d = usb.descriptors;
const _bus = @import("../bus/_bus.zig");

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
