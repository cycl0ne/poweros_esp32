// SPDX-License-Identifier: MIT
//! Host tests of usb.library's parts that need no bus: the jump table,
//! walking a device's descriptors, the class drivers' match order, and
//! reading a ROM tag from a load file's bytes.

const std = @import("std");
const sdk = @import("sdk");
const usb = sdk.usb;
const d = usb.descriptors;
const usbclass = sdk.devices.usbclass;
const loadfile = sdk.dos.loadfile;
const _bus = @import("../bus/_bus.zig");
const UsbBase = @import("../usb_base.zig").UsbBase;
const FindUSBInterface = @import("../descriptor/findusbinterface.zig").FindUSBInterface;
const FindUSBEndpoint = @import("../descriptor/findusbendpoint.zig").FindUSBEndpoint;
const NextUSBDescriptor = @import("../descriptor/nextusbdescriptor.zig").NextUSBDescriptor;

const testing = std.testing;

test {
    _ = @import("../usb_lvo.zig");
}

/// A keyboard's configuration as it comes: the configuration, an
/// interface, its HID descriptor, its interrupt endpoint; then a second
/// interface with a bulk pair.
const config_bytes = [_]u8{
    9,    d.USB_DT_CONFIG,          50,   0,                       2, 1,               0,               0x80, 50,
    9,    d.USB_DT_INTERFACE,       0,    0,                       1, d.USB_CLASS_HID, 1,               1,    0,
    9,    d.USB_DT_HID,             0x11, 0x01,                    0, 1,               d.USB_DT_REPORT, 63,   0,
    7,    d.USB_DT_ENDPOINT,        0x81, d.USB_ENDPOINT_XFER_INT, 8, 0,               10,              9,    d.USB_DT_INTERFACE,
    1,    0,                        2,    d.USB_CLASS_VENDOR_SPEC, 0, 0,               0,               7,    d.USB_DT_ENDPOINT,
    0x02, d.USB_ENDPOINT_XFER_BULK, 64,   0,                       0,
};

fn fakeDevice(bus: *_bus.Bus) _bus.Device {
    var device = _bus.Device{ .bus = bus };
    device.public.config = &config_bytes;
    device.public.config_length = config_bytes.len;
    return device;
}

test "interfaces and endpoints are found in a configuration as it came" {
    var base: UsbBase = undefined;
    var bus: _bus.Bus = undefined;
    var device = fakeDevice(&bus);
    const hid = FindUSBInterface(&base, &device.public, null, d.USB_CLASS_HID, -1, -1).?;
    try testing.expectEqual(@as(u8, 0), hid.interface_number);
    const vendor = FindUSBInterface(&base, &device.public, hid, -1, -1, -1).?;
    try testing.expectEqual(@as(u8, 1), vendor.interface_number);
    try testing.expect(FindUSBInterface(&base, &device.public, vendor, -1, -1, -1) == null);

    const in = FindUSBEndpoint(&base, &device.public, hid, d.USB_DIR_IN, d.USB_ENDPOINT_XFER_INT).?;
    try testing.expectEqual(@as(u8, 0x81), in.endpoint_address);
    // An interface's endpoints end where the next interface starts.
    try testing.expect(FindUSBEndpoint(&base, &device.public, hid, d.USB_DIR_OUT, d.USB_ENDPOINT_XFER_BULK) == null);
    const out = FindUSBEndpoint(&base, &device.public, vendor, d.USB_DIR_OUT, d.USB_ENDPOINT_XFER_BULK).?;
    try testing.expectEqual(@as(u8, 0x02), out.endpoint_address);

    const report = NextUSBDescriptor(&base, &device.public, null, d.USB_DT_HID).?;
    try testing.expectEqual(d.USB_DT_HID, report.descriptor_type);
}

test "a configuration that lies about a length ends the walk" {
    var base: UsbBase = undefined;
    var bus: _bus.Bus = undefined;
    var broken = config_bytes;
    broken[18] = 200;
    var device = _bus.Device{ .bus = &bus };
    device.public.config = &broken;
    device.public.config_length = broken.len;
    try testing.expect(FindUSBInterface(&base, &device.public, null, d.USB_CLASS_VENDOR_SPEC, -1, -1) == null);
}

test "a vendor and product match is offered before a class match" {
    const by_class = usbclass.USBMatch{ .fields = usbclass.USBMATCH_CLASS, .interface_class = d.USB_CLASS_COMM, .priority = 100 };
    const by_product = usbclass.USBMatch{ .fields = usbclass.USBMATCH_VENDOR | usbclass.USBMATCH_PRODUCT, .vendor_id = 0x0403, .product_id = 0x6001 };
    try testing.expect(usbclass.specificity(by_product) > usbclass.specificity(by_class));
    try testing.expect(usbclass.matches(by_product, 0x0403, 0x6001, 0xFF, 0, 0));
    try testing.expect(!usbclass.matches(by_product, 0x0403, 0x6015, 0xFF, 0, 0));
    try testing.expect(usbclass.matches(by_class, 0x1234, 1, d.USB_CLASS_COMM, 2, 1));
    try testing.expect(!usbclass.matches(.{}, 0, 0, 0, 0, 0));
}

/// A load file in memory, for `loadfile`'s reader.
const Bytes = struct {
    data: []const u8,
    fn readAt(context: *anyopaque, offset: u32, into: []u8) bool {
        const self: *Bytes = @ptrCast(@alignCast(context));
        if (offset > self.data.len or self.data.len - offset < into.len) return false;
        @memcpy(into, self.data[offset..][0..into.len]);
        return true;
    }
};

fn put32(into: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, into[at..][0..4], value, .little);
}

test "a ROM tag is found in a load file's data segment, by its self-offset" {
    // The header, then a data segment of 64 bytes: rubbish that looks
    // like a tag but does not point at itself, then the tag at 32, whose
    // name pointer (offset 16 into the tag, as an offset) is at 48.
    var file: [20 + 16 + 64]u8 = @splat(0);
    @memcpy(file[0..4], &loadfile.MAGIC);
    std.mem.writeInt(u16, file[4..6], loadfile.VERSION, .little);
    std.mem.writeInt(u16, file[6..8], 1, .little);
    std.mem.writeInt(u16, file[10..12], loadfile.native_machine, .little);
    file[16] = 4;
    file[20] = @intFromEnum(loadfile.SegmentKind.data);
    put32(&file, 24, 64);
    put32(&file, 28, 64);
    const seg = 36;
    std.mem.writeInt(u16, file[seg + 8 ..][0..2], 0x4AFC, .little);
    put32(&file, seg + 12, 99);
    std.mem.writeInt(u16, file[seg + 32 ..][0..2], 0x4AFC, .little);
    put32(&file, seg + 36, 32);
    put32(&file, seg + 48, 56);
    @memcpy(file[seg + 56 ..][0..4], "hid\x00");

    var bytes = Bytes{ .data = &file };
    const source = loadfile.Source{ .context = &bytes, .readAt = Bytes.readAt };
    const found = loadfile.findResident(source).?;
    try testing.expectEqual(@as(u32, 32), found.tag);
    try testing.expectEqual(@as(u32, 64), found.size);
    const name_at = loadfile.readWord(source, found, found.tag + 16).?;
    var name: [8]u8 = undefined;
    try testing.expectEqualStrings("hid", loadfile.readString(source, found, name_at, &name).?);
    // Past the segment's end there is nothing to read.
    try testing.expect(loadfile.readWord(source, found, 62) == null);

    // A file for another CPU is refused.
    std.mem.writeInt(u16, file[10..12], 1, .little);
    try testing.expect(loadfile.findResident(source) == null);
}
