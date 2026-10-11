// SPDX-License-Identifier: MIT
//! FindUSBEndpoint: an endpoint of an interface by its direction and type.

const sdk = @import("sdk");
const usb = sdk.usb;
const d = usb.descriptors;
const UsbBase = @import("../usb_base.zig").UsbBase;
const _bus = @import("../bus/_bus.zig");

/// Finds an interface's first endpoint of a direction and transfer type.
///
/// SYNOPSIS:
/// ```zig
/// fn FindUSBEndpoint(base: *UsbBase, device: *usb.USBDevice, interface_desc: *const usb.InterfaceDescriptor, direction: u32, transfer_type: u32) ?*const usb.EndpointDescriptor
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `device` - the device the interface is of.
/// - `interface_desc` - one of its interfaces, from FindUSBInterface or a
///   binding.
/// - `direction` - `USB_DIR_IN` or `USB_DIR_OUT`.
/// - `transfer_type` - `USB_ENDPOINT_XFER_*`.
///
/// RESULT:
/// The endpoint's descriptor, or null if the interface has none such.
///
/// BEHAVIOR:
/// Only the interface's own endpoints are looked at: the walk ends at the
/// next interface.
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
/// `FindUSBInterface`, `OpenUSBPipe`
///
/// EXAMPLES:
/// ```zig
/// const in = ub.FindUSBEndpoint(device, interface, d.USB_DIR_IN, d.USB_ENDPOINT_XFER_INT) orelse return false;
/// const pipe = ub.OpenUSBPipe(device, in.endpoint_address, port) orelse return false;
/// ```
pub fn FindUSBEndpoint(_: *UsbBase, device: *usb.USBDevice, interface_desc: *const usb.InterfaceDescriptor, direction: u32, transfer_type: u32) ?*const usb.EndpointDescriptor {
    const kept = _bus.deviceOf(device);
    const config = device.config orelse return null;
    var offset: u32 = @intCast(@intFromPtr(interface_desc) - @intFromPtr(config));
    while (_bus.nextDescriptor(kept, offset, 0)) |found| : (offset = found) {
        const header: *const usb.DescriptorHeader = @ptrCast(config + found);
        if (header.descriptor_type == d.USB_DT_INTERFACE) return null;
        if (header.descriptor_type != d.USB_DT_ENDPOINT) continue;
        const endpoint: *const usb.EndpointDescriptor = @ptrCast(header);
        if (endpoint.endpoint_address & d.USB_DIR_IN != direction & d.USB_DIR_IN) continue;
        if (endpoint.attributes & d.USB_ENDPOINT_XFERTYPE_MASK != transfer_type) continue;
        return endpoint;
    }
    return null;
}
