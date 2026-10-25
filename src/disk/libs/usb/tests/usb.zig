// SPDX-License-Identifier: MIT
//! Host tests of usb.library: the jump table, walking a device's
//! descriptors, the class drivers' match order, reading a ROM tag from a
//! load file's bytes, the pipe an endpoint is given, isochronous
//! transfers on such a pipe, a bus's devices coming and going, and a
//! SuperSpeed link's U1 and U2 - all
//! against a host controller that plays a script (hc.zig), a class
//! driver that counts (driver.zig) and an input.device that keeps what it
//! is told (input.zig).
//!
//! **A bus under test** has the test task for its process: the test opens
//! the controller and its clock into the bus as the process does, attaches
//! the root hub, and after each change to the script takes the hubs'
//! replies (`_bus.hubsChanged`), as the process's loop does when its port
//! is signalled.

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
const OpenUSBPipe = @import("../pipe/openusbpipe.zig").OpenUSBPipe;
const CloseUSBPipe = @import("../pipe/closeusbpipe.zig").CloseUSBPipe;
const usbhc = sdk.devices.usbhc;
const host_rom = @import("host_rom");
const kexec = host_rom.exec;
const standin = @import("hc.zig");
const standin_driver = @import("driver.zig");
const standin_input = @import("input.zig");
const ie = sdk.devices.inputevent;
const usb_init = @import("../usb_init.zig");
const usbBase = @import("../usb_base.zig").usbBase;
const _bind = @import("../bind/_bind.zig");
const _linkpower = @import("../bus/_linkpower.zig");
const timer = sdk.devices.timer;
const UsbLibrary = sdk.interface.usb.UsbBase;

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

/// A sound output's streaming interface: its empty first setting, and a
/// second with an isochronous OUT endpoint of 192-byte packets, every
/// frame - the interval at offset 33.
const speaker_bytes = [_]u8{
    9, d.USB_DT_CONFIG,    36,   0,    1,   1, 0, 0x80, 50,
    9, d.USB_DT_INTERFACE, 1,    0,    0,   1, 2, 0,    0,
    9, d.USB_DT_INTERFACE, 1,    1,    1,   1, 2, 0,    0,
    9, d.USB_DT_ENDPOINT,  0x01, 0x09, 192, 0, 1, 0,    0,
};

test "an isochronous endpoint gets a pipe at its interval, never one under a millisecond" {
    try kexec.setUp();
    defer kexec.deinit();
    var base: UsbBase = undefined;
    base.sys_base = kexec.SysBase.iface();
    var bus: _bus.Bus = undefined;
    bus.hc_io = .{};
    var port: sdk.exec.MsgPort = .{};
    var bytes = speaker_bytes;
    var device = _bus.Device{ .bus = &bus };
    device.public.config = &bytes;
    device.public.config_length = bytes.len;
    device.public.speed = usbhc.USB_SPEED_FULL;

    const pipe = OpenUSBPipe(&base, &device.public, 0x01, &port).?;
    try testing.expectEqual(usbhc.UHCMD_ISOXFER, pipe.io.std.req.command);
    try testing.expectEqual(@as(u16, 1), pipe.io.interval);
    try testing.expectEqual(@as(u16, 192), pipe.io.max_packet);
    try testing.expectEqual(@as(u32, 192), pipe.io.iso_packet);
    CloseUSBPipe(&base, pipe);

    // At high speed bInterval 1 is a microframe: refused; 4 is a
    // millisecond.
    device.public.speed = usbhc.USB_SPEED_HIGH;
    try testing.expect(OpenUSBPipe(&base, &device.public, 0x01, &port) == null);
    bytes[33] = 4;
    const fast = OpenUSBPipe(&base, &device.public, 0x01, &port).?;
    try testing.expectEqual(@as(u16, 1), fast.io.interval);
    CloseUSBPipe(&base, fast);
    try kexec.expectNoLeaks();
}

/// A SuperSpeed camera's endpoints, each with its companion: a bulk IN
/// in bursts of 8, an interrupt IN of 2 KiB an interval, an isochronous
/// IN of two bursts of 3 an interval (6 KiB) - and, read at high speed, an
/// interrupt IN of 3 x 1024 a microframe.
const camera_bytes = [_]u8{ 9, d.USB_DT_CONFIG, 64, 0, 1, 1, 0, 0x80, 50 } ++
    [_]u8{ 9, d.USB_DT_INTERFACE, 0, 0, 4, 0x0E, 2, 0, 0 } ++
    [_]u8{ 7, d.USB_DT_ENDPOINT, 0x81, d.USB_ENDPOINT_XFER_BULK, 0x00, 0x04, 0 } ++
    [_]u8{ 6, d.USB_DT_SS_ENDPOINT_COMP, 7, 0, 0, 0 } ++
    [_]u8{ 7, d.USB_DT_ENDPOINT, 0x82, d.USB_ENDPOINT_XFER_INT, 0x00, 0x04, 4 } ++
    [_]u8{ 6, d.USB_DT_SS_ENDPOINT_COMP, 1, 0, 0x00, 0x08 } ++
    [_]u8{ 7, d.USB_DT_ENDPOINT, 0x83, d.USB_ENDPOINT_XFER_ISOC, 0x00, 0x04, 4 } ++
    [_]u8{ 6, d.USB_DT_SS_ENDPOINT_COMP, 2, 1, 0x00, 0x18 } ++
    [_]u8{ 7, d.USB_DT_ENDPOINT, 0x84, d.USB_ENDPOINT_XFER_INT, 0x00, 0x14, 4 };

test "a pipe says what its endpoint moves besides a packet: bursts at SuperSpeed, transactions at high speed" {
    try kexec.setUp();
    defer kexec.deinit();
    var base: UsbBase = undefined;
    base.sys_base = kexec.SysBase.iface();
    var bus: _bus.Bus = undefined;
    bus.hc_io = .{};
    var port: sdk.exec.MsgPort = .{};
    var bytes = camera_bytes;
    var device = _bus.Device{ .bus = &bus };
    device.public.config = &bytes;
    device.public.config_length = bytes.len;
    device.public.speed = usbhc.USB_SPEED_SUPER;

    const bulk = OpenUSBPipe(&base, &device.public, 0x81, &port).?;
    try testing.expectEqual(@as(u8, 7), bulk.io.burst);
    try testing.expectEqual(@as(u16, 0), bulk.io.interval_bytes);
    CloseUSBPipe(&base, bulk);
    const interrupt = OpenUSBPipe(&base, &device.public, 0x82, &port).?;
    try testing.expectEqual(@as(u8, 1), interrupt.io.burst);
    try testing.expectEqual(@as(u8, 0), interrupt.io.mult);
    try testing.expectEqual(@as(u16, 2048), interrupt.io.interval_bytes);
    CloseUSBPipe(&base, interrupt);
    const iso = OpenUSBPipe(&base, &device.public, 0x83, &port).?;
    try testing.expectEqual(@as(u8, 2), iso.io.burst);
    try testing.expectEqual(@as(u8, 1), iso.io.mult);
    try testing.expectEqual(@as(u16, 6144), iso.io.interval_bytes);
    // Its packets are a wire packet's until the caller says otherwise.
    try testing.expectEqual(@as(u32, 1024), iso.io.iso_packet);
    CloseUSBPipe(&base, iso);
    // No companion after it: one packet at a time.
    const bare = OpenUSBPipe(&base, &device.public, 0x84, &port).?;
    try testing.expectEqual(@as(u8, 0), bare.io.burst);
    try testing.expectEqual(@as(u16, 0), bare.io.interval_bytes);
    CloseUSBPipe(&base, bare);

    // At high speed the companions mean nothing, wMaxPacketSize's bits
    // 12:11 do: two more transactions of 1024.
    device.public.speed = usbhc.USB_SPEED_HIGH;
    const high = OpenUSBPipe(&base, &device.public, 0x84, &port).?;
    try testing.expectEqual(@as(u16, 1024), high.io.max_packet);
    try testing.expectEqual(@as(u8, 2), high.io.burst);
    try testing.expectEqual(@as(u16, 3072), high.io.interval_bytes);
    CloseUSBPipe(&base, high);
    const high_bulk = OpenUSBPipe(&base, &device.public, 0x81, &port).?;
    try testing.expectEqual(@as(u8, 0), high_bulk.io.burst);
    CloseUSBPipe(&base, high_bulk);
    // At full speed nothing.
    device.public.speed = usbhc.USB_SPEED_FULL;
    const full = OpenUSBPipe(&base, &device.public, 0x84, &port).?;
    try testing.expectEqual(@as(u8, 0), full.io.burst);
    try testing.expectEqual(@as(u16, 0), full.io.interval_bytes);
    CloseUSBPipe(&base, full);
    try kexec.expectNoLeaks();
}

/// A SuperSpeed disk's interface: its Bulk-Only first setting, a bulk IN
/// at 0x82 in bursts of 4 without streams; and its UAS setting, a
/// command OUT without streams, a status IN and a data IN with 2^4
/// streams, a data OUT with 2^2 - each in bursts of 16.
const uas_bytes = [_]u8{ 9, d.USB_DT_CONFIG, 92, 0, 1, 1, 0, 0x80, 50 } ++
    [_]u8{ 9, d.USB_DT_INTERFACE, 0, 0, 1, d.USB_CLASS_MASS_STORAGE, 0x06, 0x50, 0 } ++
    [_]u8{ 7, d.USB_DT_ENDPOINT, 0x82, d.USB_ENDPOINT_XFER_BULK, 0x00, 0x04, 0 } ++
    [_]u8{ 6, d.USB_DT_SS_ENDPOINT_COMP, 3, 0, 0, 0 } ++
    [_]u8{ 9, d.USB_DT_INTERFACE, 0, 1, 4, d.USB_CLASS_MASS_STORAGE, 0x06, 0x62, 0 } ++
    [_]u8{ 7, d.USB_DT_ENDPOINT, 0x01, d.USB_ENDPOINT_XFER_BULK, 0x00, 0x04, 0 } ++
    [_]u8{ 6, d.USB_DT_SS_ENDPOINT_COMP, 15, 0, 0, 0 } ++
    [_]u8{ 7, d.USB_DT_ENDPOINT, 0x82, d.USB_ENDPOINT_XFER_BULK, 0x00, 0x04, 0 } ++
    [_]u8{ 6, d.USB_DT_SS_ENDPOINT_COMP, 15, 4, 0, 0 } ++
    [_]u8{ 7, d.USB_DT_ENDPOINT, 0x83, d.USB_ENDPOINT_XFER_BULK, 0x00, 0x04, 0 } ++
    [_]u8{ 6, d.USB_DT_SS_ENDPOINT_COMP, 15, 4, 0, 0 } ++
    [_]u8{ 7, d.USB_DT_ENDPOINT, 0x04, d.USB_ENDPOINT_XFER_BULK, 0x00, 0x04, 0 } ++
    [_]u8{ 6, d.USB_DT_SS_ENDPOINT_COMP, 15, 2, 0, 0 };

test "a stream pipe: one of the streams a SuperSpeed bulk endpoint's companion offers" {
    try kexec.setUp();
    defer kexec.deinit();
    const made = kexec.InitResident(kexec.SysBase, &usb_init.usb_library_tag, null) orelse return error.NoLibrary;
    const lib: *sdk.exec.Library = @ptrCast(@alignCast(made));
    const library: *UsbLibrary = @ptrCast(lib);
    var bus: _bus.Bus = undefined;
    bus.hc_io = .{};
    var port: sdk.exec.MsgPort = .{};
    var bytes = uas_bytes;
    var device = _bus.Device{ .bus = &bus };
    device.public.config = &bytes;
    device.public.config_length = bytes.len;
    device.public.speed = usbhc.USB_SPEED_SUPER;

    // The status pipe on its first stream and on its last: a bulk pipe
    // as OpenUSBPipe opens it, its streams named.
    const status = library.OpenUSBStreamPipe(&device.public, 0x82, 1, &port).?;
    try testing.expectEqual(usbhc.UHCMD_BULKXFER, status.io.std.req.command);
    try testing.expectEqual(@as(u8, 15), status.io.burst);
    try testing.expectEqual(@as(u16, 16), status.io.streams);
    try testing.expectEqual(@as(u16, 1), status.io.stream);
    library.CloseUSBPipe(status);
    const last = library.OpenUSBStreamPipe(&device.public, 0x83, 16, &port).?;
    try testing.expectEqual(@as(u16, 16), last.io.stream);
    library.CloseUSBPipe(last);
    try testing.expect(library.OpenUSBStreamPipe(&device.public, 0x82, 17, &port) == null);
    try testing.expect(library.OpenUSBStreamPipe(&device.public, 0x82, 0, &port) == null);
    // Four streams on the data OUT.
    const out = library.OpenUSBStreamPipe(&device.public, 0x04, 4, &port).?;
    try testing.expectEqual(@as(u16, 4), out.io.streams);
    library.CloseUSBPipe(out);
    try testing.expect(library.OpenUSBStreamPipe(&device.public, 0x04, 5, &port) == null);
    // The command pipe has none; a plain pipe names none - and finds the
    // first setting's endpoint, the stream pipe the UAS setting's.
    try testing.expect(library.OpenUSBStreamPipe(&device.public, 0x01, 1, &port) == null);
    const plain = library.OpenUSBPipe(&device.public, 0x82, &port).?;
    try testing.expectEqual(@as(u16, 0), plain.io.streams);
    try testing.expectEqual(@as(u16, 0), plain.io.stream);
    try testing.expectEqual(@as(u8, 3), plain.io.burst);
    library.CloseUSBPipe(plain);
    // Below SuperSpeed no endpoint has streams.
    device.public.speed = usbhc.USB_SPEED_HIGH;
    try testing.expect(library.OpenUSBStreamPipe(&device.public, 0x82, 1, &port) == null);

    _ = kexec.SysBase.iface().RemLibrary(lib);
    try kexec.expectNoLeaks();
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

/// A recording interface's streaming setting: an isochronous IN
/// endpoint of 64-byte packets, every frame.
const microphone_bytes = [_]u8{
    9, d.USB_DT_CONFIG,    27,   0,    1,  1, 0, 0x80, 50,
    9, d.USB_DT_INTERFACE, 1,    1,    1,  1, 2, 0,    0,
    9, d.USB_DT_ENDPOINT,  0x81, 0x05, 64, 0, 1, 0,    0,
};

/// exec, the stand-in controller opened into a bus, and a device on that
/// bus with `config`.
const Rig = struct {
    sys: *sdk.interface.exec.ExecBase,
    base: UsbBase = undefined,
    bus: _bus.Bus = undefined,
    device: _bus.Device = undefined,
    port: sdk.exec.MsgPort = .{},
    hc: *standin.HC = undefined,

    fn init(rig: *Rig, config: []const u8) !void {
        try kexec.setUp();
        rig.sys = kexec.SysBase.iface();
        rig.base.sys_base = rig.sys;
        const made = kexec.InitResident(kexec.SysBase, &standin.tag, null) orelse return error.NoDevice;
        rig.hc = standin.hcOf(@ptrCast(@alignCast(made)));
        rig.bus.hc_io = .{};
        rig.bus.hc_io.std.req.message.length = @sizeOf(usbhc.IOUsbHC);
        if (rig.sys.OpenDevice(standin.NAME, 0, &rig.bus.hc_io.std.req, 0) != 0) return error.NotOpened;
        rig.port.msg_list.init(.message);
        rig.device = _bus.Device{ .bus = &rig.bus };
        rig.device.public.config = config.ptr;
        rig.device.public.config_length = @intCast(config.len);
        rig.device.public.speed = usbhc.USB_SPEED_FULL;
    }

    fn deinit(rig: *Rig) !void {
        rig.sys.CloseDevice(&rig.bus.hc_io.std.req);
        _ = rig.sys.RemDevice(&rig.hc.dev);
        try kexec.expectNoLeaks();
        kexec.deinit();
    }
};

test "an isochronous transfer comes back with each packet's result, one lost and the transfer whole" {
    var rig: Rig = .{ .sys = undefined };
    try rig.init(&speaker_bytes);
    const pipe = OpenUSBPipe(&rig.base, &rig.device.public, 0x01, &rig.port).?;

    var data: [720]u8 = undefined;
    for (&data, 0..) |*byte, at| byte.* = @truncate(at);
    var list = [_]usbhc.UsbIsoPacket{ .{ .length = 192 }, .{ .length = 192 }, .{ .length = 96 }, .{ .length = 192 }, .{ .length = 48 } };
    rig.hc.lost = 1 << 2;
    pipe.io.std.data = &data;
    pipe.io.std.length = data.len;
    pipe.io.iso_list = &list;
    pipe.io.iso_count = list.len;
    try testing.expectEqual(@as(i8, 0), rig.sys.DoIO(&pipe.io.std.req));
    // The lost packet is a result: the transfer went, the rest whole.
    try testing.expectEqual(@as(usize, 720 - 96), pipe.io.std.actual);
    try testing.expectEqual(@as(u16, 1), pipe.io.iso_lost);
    try testing.expectEqual(usbhc.UHIOERR_MISSED, list[2].status);
    try testing.expectEqual(@as(u16, 0), list[2].actual);
    for ([_]usize{ 0, 1, 3, 4 }) |n| {
        try testing.expectEqual(@as(i8, 0), list[n].status);
        try testing.expectEqual(list[n].length, list[n].actual);
    }
    // What went is every packet but the third, each from its place.
    try testing.expectEqual(@as(u32, 720 - 96), rig.hc.sent_length);
    try testing.expectEqualSlices(u8, data[0..384], rig.hc.sent[0..384]);
    try testing.expectEqualSlices(u8, data[480..720], rig.hc.sent[384..624]);
    try testing.expectEqual(@as(u16, 100), pipe.io.iso_frame);
    try testing.expectEqual(@as(u16, 0), pipe.io.iso_gap);

    CloseUSBPipe(&rig.base, pipe);
    try rig.deinit();
}

test "a stream that ran dry says by how much in the next transfer's gap" {
    var rig: Rig = .{ .sys = undefined };
    try rig.init(&speaker_bytes);
    const pipe = OpenUSBPipe(&rig.base, &rig.device.public, 0x01, &rig.port).?;
    var data: [1920]u8 = @splat(0);
    pipe.io.std.data = &data;
    pipe.io.std.length = data.len;
    rig.hc.gap_before = 1;
    rig.hc.gap = 7;

    // Ten packets of the endpoint's 192 bytes, a frame each.
    try testing.expectEqual(@as(i8, 0), rig.sys.DoIO(&pipe.io.std.req));
    try testing.expectEqual(@as(u16, 100), pipe.io.iso_frame);
    try testing.expectEqual(@as(u16, 0), pipe.io.iso_gap);
    try testing.expectEqual(@as(usize, 1920), pipe.io.std.actual);
    // The next comes seven frames after the last one ended.
    try testing.expectEqual(@as(i8, 0), rig.sys.DoIO(&pipe.io.std.req));
    try testing.expectEqual(@as(u16, 117), pipe.io.iso_frame);
    try testing.expectEqual(@as(u16, 7), pipe.io.iso_gap);
    try testing.expectEqual(@as(u16, 0), pipe.io.iso_lost);

    // One placed in a frame of its own, from the frame the controller is
    // in: what it skipped is its gap.
    var info: usbhc.USBHCInfo = .{};
    var query = rig.bus.hc_io;
    query.std.req.command = usbhc.UHCMD_QUERYDEVICE;
    query.std.data = &info;
    query.std.length = @sizeOf(usbhc.USBHCInfo);
    try testing.expectEqual(@as(i8, 0), rig.sys.DoIO(&query.std.req));
    try testing.expectEqual(@as(u32, 127), info.frame);
    pipe.io.flags |= usbhc.UHF_ISO_FRAME;
    pipe.io.iso_frame = @truncate(info.frame + 20);
    try testing.expectEqual(@as(i8, 0), rig.sys.DoIO(&pipe.io.std.req));
    try testing.expectEqual(@as(u16, 147), pipe.io.iso_frame);
    try testing.expectEqual(@as(u16, 20), pipe.io.iso_gap);

    CloseUSBPipe(&rig.base, pipe);
    try rig.deinit();
}

test "an isochronous IN transfer's packets each at their place, a short one as long as it came" {
    var rig: Rig = .{ .sys = undefined };
    try rig.init(&microphone_bytes);
    const pipe = OpenUSBPipe(&rig.base, &rig.device.public, 0x81, &rig.port).?;
    try testing.expectEqual(usbhc.UHCMD_ISOXFER, pipe.io.std.req.command);

    var data: [192]u8 = @splat(0xEE);
    var list = [_]usbhc.UsbIsoPacket{ .{ .length = 64 }, .{ .length = 64 }, .{ .length = 64 } };
    rig.hc.short_packet = 1;
    rig.hc.short_bytes = 10;
    pipe.io.std.data = &data;
    pipe.io.std.length = data.len;
    pipe.io.iso_list = &list;
    pipe.io.iso_count = list.len;
    try testing.expectEqual(@as(i8, 0), rig.sys.DoIO(&pipe.io.std.req));
    try testing.expectEqual(@as(usize, 64 + 10 + 64), pipe.io.std.actual);
    try testing.expectEqual(@as(u16, 10), list[1].actual);
    try testing.expectEqual(@as(u16, 0), pipe.io.iso_lost);
    // Each packet at its asked place; the short one leaves the rest of
    // its room as it was.
    for (data[0..64]) |byte| try testing.expectEqual(@as(u8, 0), byte);
    for (data[64..74]) |byte| try testing.expectEqual(@as(u8, 1), byte);
    for (data[74..128]) |byte| try testing.expectEqual(@as(u8, 0xEE), byte);
    for (data[128..192]) |byte| try testing.expectEqual(@as(u8, 2), byte);

    CloseUSBPipe(&rig.base, pipe);
    try rig.deinit();
}

// --- a bus's devices coming and going ------------------------------------------

/// usb.library made, the stand-in controller and its clock opened into a
/// bus the test task is the process of, the stand-in class driver in the
/// library's table, taking HID interfaces, and the stand-in input.device.
/// Not to be moved once made: the bus's devices point at it.
const BusRig = struct {
    sys: *sdk.interface.exec.ExecBase,
    library: *sdk.exec.Library,
    base: *UsbBase,
    hc: *standin.HC,
    driver: *standin_driver.Driver,
    input: *standin_input.Input,
    bus: _bus.Bus,

    fn init(rig: *BusRig) !void {
        try kexec.setUp();
        rig.sys = kexec.SysBase.iface();
        const made = kexec.InitResident(kexec.SysBase, &usb_init.usb_library_tag, null) orelse return error.NoLibrary;
        rig.library = @ptrCast(@alignCast(made));
        rig.base = usbBase(rig.library);
        const hc_made = kexec.InitResident(kexec.SysBase, &standin.tag, null) orelse return error.NoDevice;
        rig.hc = standin.hcOf(@ptrCast(@alignCast(hc_made)));
        const driver_made = kexec.InitResident(kexec.SysBase, &standin_driver.tag, null) orelse return error.NoDevice;
        rig.driver = standin_driver.driverOf(@ptrCast(@alignCast(driver_made)));
        const input_made = kexec.InitResident(kexec.SysBase, &standin_input.tag, null) orelse return error.NoDevice;
        rig.input = standin_input.inputOf(@ptrCast(@alignCast(input_made)));

        // The table as DEVS:usb/ would have given it, freed with the
        // library.
        const memory = rig.sys.AllocMem(@sizeOf(_bind.Drivers), sdk.exec.MEMF_CLEAR) orelse return error.NoMemory;
        const drivers: *_bind.Drivers = @ptrCast(@alignCast(memory));
        drivers.* = .{ .count = 1 };
        @memcpy(drivers.list[0].name[0..standin_driver.NAME.len], standin_driver.NAME);
        drivers.list[0].matches[0] = .{ .fields = usbclass.USBMATCH_CLASS, .interface_class = d.USB_CLASS_HID };
        drivers.list[0].match_count = 1;
        rig.base.drivers = drivers;

        rig.bus = .{ .usb_base = rig.base, .number = 0, .hc_name = standin.NAME, .hc_unit = 0 };
        const port = rig.sys.CreateMsgPort() orelse return error.NoPort;
        rig.bus.port = port;
        rig.bus.hc_io.std.req.message.reply_port = port;
        rig.bus.hc_io.std.req.message.length = @sizeOf(usbhc.IOUsbHC);
        if (rig.sys.OpenDevice(standin.NAME, 0, &rig.bus.hc_io.std.req, 0) != 0) return error.NotOpened;
        rig.bus.delay_io.node.message.reply_port = port;
        rig.bus.delay_io.node.message.length = @sizeOf(timer.TimeRequest);
        if (rig.sys.OpenDevice(standin.NAME, standin.CLOCK_UNIT, &rig.bus.delay_io.node, 0) != 0) return error.NotOpened;
    }

    /// The root hub attached, as the process does once it has the
    /// controller.
    fn start(rig: *BusRig) *_bus.Device {
        rig.bus.root = _bus.attach(&rig.bus, null, 0, usbhc.USB_SPEED_FULL);
        return rig.bus.root.?;
    }

    /// The devices on the library's list.
    fn count(rig: *BusRig) u32 {
        const library: *UsbLibrary = @ptrCast(rig.library);
        const list = library.ObtainUSBDeviceList();
        defer library.ReleaseUSBDeviceList();
        var found: u32 = 0;
        var it = list.iterator();
        while (it.next()) |_| found += 1;
        return found;
    }

    /// Whether `address` is given out on the bus.
    fn inUse(rig: *const BusRig, address: u8) bool {
        return rig.bus.addresses[address / 32] & (@as(u32, 1) << @intCast(address % 32)) != 0;
    }

    /// The bus stopped as the process stops it, and everything made freed.
    fn deinit(rig: *BusRig) !void {
        if (rig.bus.root) |root| _bus.detach(&rig.bus, root);
        rig.bus.root = null;
        rig.bus.input.end(rig.sys);
        rig.sys.CloseDevice(&rig.bus.delay_io.node);
        rig.sys.CloseDevice(&rig.bus.hc_io.std.req);
        rig.sys.DeleteMsgPort(rig.bus.port.?);
        _ = rig.sys.RemDevice(&rig.hc.dev);
        _ = rig.sys.RemDevice(&rig.driver.dev);
        _ = rig.sys.RemDevice(&rig.input.dev);
        _ = rig.sys.RemLibrary(rig.library);
        try kexec.expectNoLeaks();
        kexec.deinit();
    }
};

fn childOf(device: *_bus.Device, port: u8) ?*_bus.Device {
    return device.hub.?.children[port - 1];
}

/// That `event` says the device at `address` on bus 0 came or went.
fn expectUsbEvent(event: ie.InputEvent, subclass: u32, address: u8) !void {
    try testing.expectEqual(ie.IECLASS_USB, event.class);
    try testing.expectEqual(subclass, event.subclass);
    try testing.expectEqual(@as(u32, address), event.code);
}

test "a device on the root hub is addressed, configured and bound, and goes when pulled" {
    var rig: BusRig = undefined;
    try rig.init();
    const hc = rig.hc;
    _ = standin.addRoot(hc, 2);
    const keyboard = standin.addDevice(hc, standin.root, 1, usbhc.USB_SPEED_LOW, 0x046D, 0xC31C, d.USB_CLASS_HID, .{ "Maker", "Keyboard", "K1" });
    standin.plug(hc, keyboard);

    const library: *UsbLibrary = @ptrCast(rig.library);
    const signal = rig.sys.AllocSignal(-1);
    const mask = @as(u32, 1) << @intCast(signal);
    const notify = library.AddUSBNotify(rig.sys.FindTask(null).?, mask).?;
    _ = rig.sys.SetSignal(0, mask);

    const root = rig.start();
    try testing.expectEqual(@as(u8, 1), root.public.address);
    try testing.expect(root.public.flags & usb.USBDF_HUB != 0);
    try testing.expectEqual(@as(u8, 2), root.hub.?.ports);
    const device = childOf(root, 1).?;
    try testing.expectEqual(@as(u8, 2), device.public.address);
    try testing.expectEqual(@as(u8, 2), hc.functions[keyboard].address);
    try testing.expectEqual(usbhc.USB_SPEED_LOW, device.public.speed);
    try testing.expectEqual(@as(u8, 8), device.public.descriptor.max_packet_size0);
    try testing.expectEqual(@as(u16, 0xC31C), device.public.descriptor.product_id);
    try testing.expect(device.public.flags & usb.USBDF_CONFIGURED != 0);
    try testing.expectEqual(@as(u8, 1), hc.functions[keyboard].configuration);
    try testing.expectEqualStrings("Keyboard", std.mem.span(device.public.product.?));
    try testing.expectEqualStrings("K1", std.mem.span(device.public.serial.?));
    try testing.expectEqual(@as(u32, 1), rig.driver.binds);
    try testing.expectEqual(@as(u8, 0), rig.driver.last_interface);
    try testing.expectEqualStrings(standin_driver.NAME, std.mem.span(device.public.drivers[0].?));
    try testing.expectEqual(@as(u32, 2), rig.count());
    try testing.expect(rig.sys.SetSignal(0, mask) & mask != 0);
    // The ports' power and the debounce were waited for, on the clock.
    try testing.expect(hc.clock >= 200_000);
    // The root hub's status transfer is out, held until a port changes.
    try testing.expect(root.hub.?.pending != 0);
    try testing.expect(hc.functions[standin.root].held != null);
    // input.device told of both, the root hub first, the keyboard with
    // its ids.
    var events = standin_input.written(rig.input);
    try testing.expectEqual(@as(usize, 2), events.len);
    try expectUsbEvent(events[0], ie.IESUBCLASS_USB_ATTACHED, 1);
    try expectUsbEvent(events[1], ie.IESUBCLASS_USB_ATTACHED, 2);
    try testing.expectEqual(@as(i32, 0x046D), events[1].x);
    try testing.expectEqual(@as(i32, 0xC31C), events[1].y);

    standin.pull(hc, keyboard);
    _bus.hubsChanged(&rig.bus);
    events = standin_input.written(rig.input);
    try testing.expectEqual(@as(usize, 3), events.len);
    try expectUsbEvent(events[2], ie.IESUBCLASS_USB_DETACHED, 2);
    try testing.expectEqual(@as(i32, 0xC31C), events[2].y);
    try testing.expect(childOf(root, 1) == null);
    try testing.expectEqual(@as(u32, 1), rig.driver.unbinds);
    try testing.expectEqual(@as(u32, 0), rig.driver.holding);
    try testing.expectEqual(@as(u32, 1), rig.count());
    try testing.expect(!rig.inUse(2));
    try testing.expect(rig.sys.SetSignal(0, mask) & mask != 0);
    try testing.expect(hc.functions[standin.root].held != null);

    library.RemUSBNotify(notify);
    rig.sys.FreeSignal(signal);
    try rig.deinit();
}

test "a hub with two devices, a third plugged in later, and the hub pulled with all three" {
    var rig: BusRig = undefined;
    try rig.init();
    const hc = rig.hc;
    _ = standin.addRoot(hc, 1);
    const hub = standin.addHub(hc, standin.root, 1, usbhc.USB_SPEED_HIGH, 4);
    const mouse = standin.addDevice(hc, hub, 1, usbhc.USB_SPEED_FULL, 0x1234, 0x0001, d.USB_CLASS_HID, .{ "", "Mouse", "" });
    const stick = standin.addDevice(hc, hub, 3, usbhc.USB_SPEED_HIGH, 0x0781, 0x5567, d.USB_CLASS_MASS_STORAGE, .{ "", "Stick", "" });
    const keyboard = standin.addDevice(hc, hub, 2, usbhc.USB_SPEED_LOW, 0x1234, 0x0002, d.USB_CLASS_HID, .{ "", "Keyboard", "" });
    standin.plug(hc, hub);
    standin.plug(hc, mouse);
    standin.plug(hc, stick);

    const root = rig.start();
    const hub_device = childOf(root, 1).?;
    try testing.expect(hub_device.public.flags & usb.USBDF_HUB != 0);
    try testing.expectEqual(@as(u8, 2), hub_device.public.address);
    try testing.expectEqual(@as(u8, 1), hub_device.public.depth);
    try testing.expectEqual(@as(u8, 4), hub_device.hub.?.ports);
    try testing.expectEqualStrings("usb.library", std.mem.span(hub_device.public.drivers[0].?));
    // The ports looked at in order: the mouse on 1, the stick on 3.
    const mouse_device = childOf(hub_device, 1).?;
    const stick_device = childOf(hub_device, 3).?;
    try testing.expectEqual(@as(u8, 3), mouse_device.public.address);
    try testing.expectEqual(@as(u8, 4), stick_device.public.address);
    try testing.expectEqual(@as(u8, 2), mouse_device.public.depth);
    try testing.expectEqual(&hub_device.public, mouse_device.public.hub.?);
    try testing.expectEqual(@as(u8, 3), stick_device.public.port);
    // A full-speed device behind a high-speed hub is reached through that
    // hub's translator, at its port; a high-speed one needs none.
    try testing.expectEqual(@as(u8, 2), mouse_device.hub_address);
    try testing.expectEqual(@as(u8, 1), mouse_device.hub_port);
    try testing.expectEqual(@as(u8, 0), stick_device.hub_address);
    // The stick is configured, and no driver of the table takes it.
    try testing.expect(stick_device.public.flags & usb.USBDF_CONFIGURED != 0);
    try testing.expect(stick_device.public.drivers[0] == null);
    try testing.expectEqual(@as(u32, 1), rig.driver.binds);
    try testing.expectEqual(@as(u32, 4), rig.count());

    standin.plug(hc, keyboard);
    _bus.hubsChanged(&rig.bus);
    const keyboard_device = childOf(hub_device, 2).?;
    try testing.expectEqual(@as(u8, 5), keyboard_device.public.address);
    try testing.expectEqual(@as(u8, 2), keyboard_device.hub_port);
    try testing.expectEqual(@as(u32, 2), rig.driver.binds);
    try testing.expectEqual(@as(u32, 5), rig.count());

    // The hub's own status transfer comes back detached after the root
    // hub's change: it is found replied when the hub is taken down.
    // A hub is told of before what is in it.
    var events = standin_input.written(rig.input);
    try testing.expectEqual(@as(usize, 5), events.len);
    for ([_]u8{ 1, 2, 3, 4, 5 }, events) |address, event| try expectUsbEvent(event, ie.IESUBCLASS_USB_ATTACHED, address);

    standin.pull(hc, hub);
    _bus.hubsChanged(&rig.bus);
    // What hangs off the hub goes before it, port by port.
    events = standin_input.written(rig.input);
    try testing.expectEqual(@as(usize, 9), events.len);
    for ([_]u8{ 3, 5, 4, 2 }, events[5..]) |address, event| try expectUsbEvent(event, ie.IESUBCLASS_USB_DETACHED, address);
    try testing.expect(childOf(root, 1) == null);
    try testing.expectEqual(@as(u32, 2), rig.driver.unbinds);
    try testing.expectEqual(@as(u32, 0), rig.driver.holding);
    try testing.expectEqual(@as(u32, 1), rig.count());
    for ([_]u8{ 2, 3, 4, 5 }) |address| try testing.expect(!rig.inUse(address));
    try testing.expect(rig.inUse(1));
    try rig.deinit();
}

test "a port whose power an over-current took gets it back, and the mouse in it is found" {
    var rig: BusRig = undefined;
    try rig.init();
    const hc = rig.hc;
    _ = standin.addRoot(hc, 1);
    const hub = standin.addHub(hc, standin.root, 1, usbhc.USB_SPEED_HIGH, 4);
    const mouse = standin.addDevice(hc, hub, 3, usbhc.USB_SPEED_HIGH, 0x3151, 0x5007, d.USB_CLASS_HID, .{ "", "Mouse", "" });
    // The hub's ports 1 and 3 trip as they come on, the mouse already in 3.
    hc.functions[hub].trips = 1 << 0 | 1 << 2;
    standin.plug(hc, hub);
    standin.plug(hc, mouse);

    const root = rig.start();
    const hub_device = childOf(root, 1).?;
    const mouse_device = childOf(hub_device, 3).?;
    try testing.expectEqual(@as(u16, 0x5007), mouse_device.public.descriptor.product_id);
    try testing.expect(mouse_device.public.flags & usb.USBDF_CONFIGURED != 0);
    try testing.expectEqual(@as(u32, 1), rig.driver.binds);
    // Both ports have their power back, the empty one too, and no change
    // is left on either.
    for ([_]u8{ 0, 2 }) |at| {
        try testing.expect(hc.functions[hub].port_status[at] & d.USB_PORT_STAT_POWER != 0);
        try testing.expectEqual(@as(u16, 0), hc.functions[hub].port_change[at]);
    }
    try testing.expect(childOf(hub_device, 1) == null);
    try rig.deinit();
}

test "a stalled request: strings left out, a configuration that never comes leaves the device failed" {
    var rig: BusRig = undefined;
    try rig.init();
    const hc = rig.hc;
    _ = standin.addRoot(hc, 2);
    const quiet = standin.addDevice(hc, standin.root, 1, usbhc.USB_SPEED_FULL, 0x1234, 0x0010, d.USB_CLASS_HID, .{ "Maker", "Quiet", "" });
    hc.functions[quiet].stall_request = d.USB_REQ_GET_DESCRIPTOR;
    hc.functions[quiet].stall_kind = d.USB_DT_STRING;
    const broken = standin.addDevice(hc, standin.root, 2, usbhc.USB_SPEED_FULL, 0x1234, 0x0011, d.USB_CLASS_HID, .{ "", "Broken", "" });
    hc.functions[broken].stall_request = d.USB_REQ_GET_DESCRIPTOR;
    hc.functions[broken].stall_kind = d.USB_DT_CONFIG;
    standin.plug(hc, quiet);
    standin.plug(hc, broken);

    const root = rig.start();
    const quiet_device = childOf(root, 1).?;
    try testing.expect(quiet_device.public.flags & usb.USBDF_CONFIGURED != 0);
    try testing.expect(quiet_device.public.product == null);
    try testing.expect(quiet_device.public.manufacturer == null);
    try testing.expect(quiet_device.public.drivers[0] != null);

    // On the list, with its address, unconfigured and offered to no
    // driver.
    const broken_device = childOf(root, 2).?;
    try testing.expect(broken_device.public.flags & usb.USBDF_FAILED != 0);
    try testing.expect(broken_device.public.flags & usb.USBDF_CONFIGURED == 0);
    try testing.expectEqual(@as(u8, 3), broken_device.public.address);
    try testing.expectEqual(@as(u8, 0), hc.functions[broken].configuration);
    try testing.expect(broken_device.public.drivers[0] == null);
    try testing.expectEqual(@as(u32, 1), rig.driver.binds);
    try testing.expectEqual(@as(u32, 3), rig.count());

    standin.pull(hc, broken);
    _bus.hubsChanged(&rig.bus);
    try testing.expect(childOf(root, 2) == null);
    try testing.expectEqual(@as(u32, 0), rig.driver.unbinds);
    try testing.expectEqual(@as(u32, 2), rig.count());
    try testing.expect(!rig.inUse(3));
    try rig.deinit();
}

test "a device pulled in the middle of its enumeration goes at its hub's next change" {
    var rig: BusRig = undefined;
    try rig.init();
    const hc = rig.hc;
    _ = standin.addRoot(hc, 1);
    const device = standin.addDevice(hc, standin.root, 1, usbhc.USB_SPEED_FULL, 0x1234, 0x0020, d.USB_CLASS_HID, .{ "", "Gone", "" });
    // Its first eight bytes and its address answered, then pulled.
    hc.functions[device].pull_after = 2;
    standin.plug(hc, device);

    const root = rig.start();
    const half = childOf(root, 1).?;
    try testing.expect(half.public.flags & usb.USBDF_FAILED != 0);
    try testing.expectEqual(@as(u8, 2), half.public.address);
    // Told of, failed as it is: it is on the list.
    try expectUsbEvent(standin_input.written(rig.input)[1], ie.IESUBCLASS_USB_ATTACHED, 2);
    try testing.expectEqual(@as(u32, 0), rig.driver.binds);
    try testing.expectEqual(@as(u32, 2), rig.count());
    // The port's change was there when the status transfer went: it is
    // answered already.
    try testing.expect(hc.functions[standin.root].held == null);

    _bus.hubsChanged(&rig.bus);
    try testing.expect(childOf(root, 1) == null);
    try testing.expectEqual(@as(u32, 1), rig.count());
    try testing.expect(!rig.inUse(2));

    // Back in: a whole device, at an address not the one just freed.
    hc.functions[device].pull_after = standin.none;
    standin.plug(hc, device);
    _bus.hubsChanged(&rig.bus);
    const whole = childOf(root, 1).?;
    try testing.expect(whole.public.flags & usb.USBDF_CONFIGURED != 0);
    try testing.expectEqual(@as(u8, 3), whole.public.address);
    try testing.expectEqual(@as(u32, 1), rig.driver.binds);
    try rig.deinit();
}

test "a SuperSpeed hub: its own descriptor and depth, devices at 512 bytes, a failed link warm reset" {
    var rig: BusRig = undefined;
    try rig.init();
    const hc = rig.hc;
    _ = standin.addRoot(hc, 2);
    const hub = standin.addHub(hc, standin.root, 1, usbhc.USB_SPEED_SUPER, 4);
    const stick = standin.addDevice(hc, hub, 1, usbhc.USB_SPEED_SUPER, 0x0781, 0x5581, d.USB_CLASS_MASS_STORAGE, .{ "", "Stick", "" });
    const late = standin.addDevice(hc, hub, 2, usbhc.USB_SPEED_SUPER, 0x1234, 0x0030, d.USB_CLASS_HID, .{ "", "Late", "" });
    hc.functions[late].inactive = true;
    const below = standin.addHub(hc, hub, 3, usbhc.USB_SPEED_SUPER, 2);
    const direct = standin.addDevice(hc, standin.root, 2, usbhc.USB_SPEED_SUPER, 0x0781, 0x5582, d.USB_CLASS_MASS_STORAGE, .{ "", "Direct", "" });
    for ([_]u8{ hub, stick, late, below, direct }) |index| standin.plug(hc, index);

    const root = rig.start();
    const hub_device = childOf(root, 1).?;
    try testing.expectEqual(usbhc.USB_SPEED_SUPER, hub_device.public.speed);
    try testing.expect(hub_device.hub.?.super);
    try testing.expectEqual(@as(u8, 4), hub_device.hub.?.ports);
    // Its depth before anything below it was reset: 0 on a root port, 1
    // below it.
    try testing.expectEqual(@as(u16, 0), hc.functions[hub].hub_depth);
    try testing.expectEqual(@as(u16, 1), hc.functions[below].hub_depth);
    try testing.expect(childOf(hub_device, 3).?.hub.?.super);
    // Endpoint 0 at 512 bytes from the first transfer on, the descriptor
    // saying so as an exponent; no translator in the way.
    const stick_device = childOf(hub_device, 1).?;
    try testing.expectEqual(usbhc.USB_SPEED_SUPER, stick_device.public.speed);
    try testing.expectEqual(@as(u8, 9), stick_device.public.descriptor.max_packet_size0);
    try testing.expectEqual(@as(u16, 512), hc.functions[stick].max_packet0);
    try testing.expect(stick_device.public.flags & usb.USBDF_CONFIGURED != 0);
    try testing.expectEqual(@as(u8, 0), stick_device.hub_address);
    // The root port says SuperSpeed in the USB 2 form.
    const direct_device = childOf(root, 2).?;
    try testing.expectEqual(usbhc.USB_SPEED_SUPER, direct_device.public.speed);
    try testing.expectEqual(@as(u16, 512), hc.functions[direct].max_packet0);

    // The failed link was warm reset; what is on it comes at the hub's
    // next change.
    try testing.expectEqual(@as(u32, 1), hc.functions[hub].warm_resets);
    try testing.expect(childOf(hub_device, 2) == null);
    _bus.hubsChanged(&rig.bus);
    const late_device = childOf(hub_device, 2).?;
    try testing.expect(late_device.public.flags & usb.USBDF_CONFIGURED != 0);
    try testing.expectEqual(@as(u32, 1), rig.driver.binds);
    // Every change was cleared by the hub's own features.
    for (hc.functions[hub].port_change) |change| try testing.expectEqual(@as(u16, 0), change);
    try testing.expectEqual(@as(u32, 6), rig.count());

    standin.pull(hc, hub);
    _bus.hubsChanged(&rig.bus);
    try testing.expectEqual(@as(u32, 2), rig.count());
    try testing.expectEqual(@as(u32, 0), rig.driver.holding);
    try rig.deinit();
}

test "a SuperSpeed hub's port status in the USB 2 form" {
    const status = d.superPortStatus(.{
        .status = d.USB_PORT_STAT_CONNECTION | d.USB_PORT_STAT_ENABLE | d.USB_SS_PORT_STAT_POWER | d.USB_SS_LINK_U3 << d.USB_SS_PORT_STAT_LINK_STATE_SHIFT,
        .change = d.USB_PORT_STAT_C_CONNECTION | d.USB_SS_PORT_STAT_C_BH_RESET | d.USB_SS_PORT_STAT_C_LINK_STATE | d.USB_SS_PORT_STAT_C_CONFIG_ERROR,
    });
    try testing.expectEqual(d.USB_PORT_STAT_CONNECTION | d.USB_PORT_STAT_ENABLE | d.USB_PORT_STAT_POWER | d.USB_PORT_STAT_SUSPEND | d.USB_PORT_STAT_SUPER_SPEED, status.status);
    try testing.expectEqual(d.USB_PORT_STAT_C_CONNECTION | d.USB_PORT_STAT_C_RESET | d.USB_PORT_STAT_C_SUSPEND | d.USB_PORT_STAT_C_ENABLE, status.change);
    // Nothing on it: no speed, and the link state alone.
    const empty_port: u16 = d.USB_SS_PORT_STAT_POWER | d.USB_SS_LINK_INACTIVE << d.USB_SS_PORT_STAT_LINK_STATE_SHIFT;
    try testing.expectEqual(d.USB_PORT_STAT_POWER, d.superPortStatus(.{ .status = empty_port }).status);
    try testing.expectEqual(d.USB_SS_LINK_INACTIVE, d.superLinkState(empty_port));
}

test "a BOS's SuperSpeed capability, after another, and none in one cut short" {
    const bos = [_]u8{ 5, d.USB_DT_BOS, 22, 0, 2 } ++
        [_]u8{ 7, d.USB_DT_DEVICE_CAPABILITY, 2, 2, 0, 0, 0 } ++
        [_]u8{ 10, d.USB_DT_DEVICE_CAPABILITY, d.USB_CAP_SUPERSPEED, 0, 0x0E, 0, 1, 10, 0x20, 0x01 };
    const capability = d.superSpeedCapabilityOf(&bos).?;
    try testing.expectEqual(@as(u8, 10), capability.u1_exit);
    try testing.expectEqual(@as(u16, 0x120), capability.u2_exit);
    try testing.expect(d.superSpeedCapabilityOf(bos[0..15]) == null);
    try testing.expect(d.superSpeedCapabilityOf(bos[0..12]) == null);
}

test "the way back from U1 and U2: on a root port, behind a hub, and timeouts past their fields" {
    // The root hub's ports: 2 and 20 µs; a hub on one, 4 and 100 µs, its
    // header decode 0.4 µs and delay 400 ns; a device of 10 and 32 µs.
    const root: _linkpower.Upstream = .{ .exits = .{ 2, 20 }, .root = true };
    const direct = _linkpower.pathOf(.{ 10, 32 }, root, 0);
    try testing.expectEqual([2]u32{ 12580, 34580 }, direct.mel);
    try testing.expectEqual([2]u32{ 10000, 32000 }, direct.pel);
    try testing.expectEqual([2]u32{ 10000, 32000 }, direct.sel);
    try testing.expectEqual(d.SelData{ .u1_sel = 10, .u1_pel = 10, .u2_sel = 32, .u2_pel = 32 }, _linkpower.selOf(direct));
    try testing.expectEqual(@as(u16, 35), _linkpower.exitLatencyOf(direct, .{ 10, 32 }));
    // Without U2 only U1's way counts.
    try testing.expectEqual(@as(u16, 13), _linkpower.exitLatencyOf(direct, .{ 10, 0 }));
    try testing.expectEqual(@as(u8, 30), _linkpower.timeoutOf(_linkpower.U1, direct));
    try testing.expectEqual(@as(u8, 1), _linkpower.timeoutOf(_linkpower.U2, direct));

    const hub_path = _linkpower.pathOf(.{ 4, 100 }, root, 0);
    const hub: _linkpower.Upstream = .{ .path = hub_path, .exits = .{ 4, 100 }, .header_latency = 4, .hub_delay = 400 };
    const behind = _linkpower.pathOf(.{ 10, 32 }, hub, 1);
    try testing.expectEqual([2]u32{ 17860, 203860 }, behind.mel);
    // U2's wake passed up through the hub takes longer than the last
    // link's own.
    try testing.expectEqual([2]u32{ 10000, 197000 }, behind.pel);
    try testing.expectEqual([2]u32{ 12350, 199350 }, behind.sel);
    try testing.expectEqual(d.SelData{ .u1_sel = 13, .u1_pel = 10, .u2_sel = 200, .u2_pel = 197 }, _linkpower.selOf(behind));
    try testing.expectEqual(@as(u16, 204), _linkpower.exitLatencyOf(behind, .{ 10, 32 }));
    try testing.expectEqual(@as(u8, 38), _linkpower.timeoutOf(_linkpower.U1, behind));
    try testing.expectEqual(@as(u8, 3), _linkpower.timeoutOf(_linkpower.U2, behind));

    // Past 127 µs, past 254 x 256 µs: the port leaves the link to the
    // device.
    const long: _linkpower.Latencies = .{ .sel = .{ 50_000, 30_000_000 } };
    try testing.expectEqual(d.USB_LPM_TIMEOUT_ACCEPT, _linkpower.timeoutOf(_linkpower.U1, long));
    try testing.expectEqual(d.USB_LPM_TIMEOUT_ACCEPT, _linkpower.timeoutOf(_linkpower.U2, long));
    // SET_SEL's U1 fields hold at most 255 µs.
    try testing.expectEqual(@as(u8, 0xFF), _linkpower.selOf(.{ .sel = .{ 300_000, 0 } }).u1_sel);
}

test "a SuperSpeed device's link rests in U1 and U2: not a hub's, not one with isochronous data, and not a state refused" {
    var rig: BusRig = undefined;
    try rig.init();
    const hc = rig.hc;
    const root_index = standin.addRoot(hc, 2);
    hc.functions[root_index].descriptor.bcd_usb = 0x0210;
    hc.functions[root_index].exits = .{ 2, 20 };
    const hub = standin.addHub(hc, standin.root, 1, usbhc.USB_SPEED_SUPER, 2);
    hc.functions[hub].exits = .{ 4, 100 };
    const stick = standin.addDevice(hc, hub, 1, usbhc.USB_SPEED_SUPER, 0x0781, 0x5581, d.USB_CLASS_MASS_STORAGE, .{ "", "Stick", "" });
    hc.functions[stick].exits = .{ 10, 32 };
    const speaker = standin.addDevice(hc, hub, 2, usbhc.USB_SPEED_SUPER, 0x1234, 0x0040, d.USB_CLASS_AUDIO, .{ "", "Speaker", "" });
    hc.functions[speaker].exits = .{ 10, 32 };
    standin.makeIsochronous(hc, speaker);
    const direct = standin.addDevice(hc, standin.root, 2, usbhc.USB_SPEED_SUPER, 0x0781, 0x5582, d.USB_CLASS_MASS_STORAGE, .{ "", "Direct", "" });
    hc.functions[direct].exits = .{ 10, 32 };
    hc.functions[direct].refused_feature = d.USB_DEVICE_U2_ENABLE;
    for ([_]u8{ hub, stick, speaker, direct }) |index| standin.plug(hc, index);

    const root = rig.start();
    try testing.expectEqual([2]u16{ 2, 20 }, root.exits);
    const hub_device = childOf(root, 1).?;
    try testing.expectEqual(@as(u8, standin.hub_header_latency), hub_device.hub.?.header_latency);

    // Behind the hub: the way back as worked out above, both states.
    const stick_device = childOf(hub_device, 1).?;
    try testing.expectEqual(d.SelData{ .u1_sel = 13, .u1_pel = 10, .u2_sel = 200, .u2_pel = 197 }, hc.functions[stick].sel);
    try testing.expectEqual(@as(u16, 204), hc.functions[stick].sel_latency);
    try testing.expectEqual(@as(u32, 3), hc.functions[stick].features);
    try testing.expectEqual([2]u8{ 38, 3 }, hc.functions[hub].timeouts[0]);
    try testing.expectEqual(usb.USBDF_U1 | usb.USBDF_U2, stick_device.public.flags & (usb.USBDF_U1 | usb.USBDF_U2));
    // The speaker's data cannot wait: nothing sent it, nothing at its port.
    try testing.expectEqual(@as(u16, 0), hc.functions[speaker].sel_latency);
    try testing.expectEqual(@as(u32, 0), hc.functions[speaker].features);
    try testing.expectEqual([2]u8{ 0, 0 }, hc.functions[hub].timeouts[1]);
    // The hub's own link stays in U0.
    try testing.expectEqual([2]u8{ 0, 0 }, hc.functions[root_index].timeouts[0]);
    try testing.expectEqual(@as(u32, 0), hc.functions[hub].features);
    try testing.expect(hub_device.public.flags & (usb.USBDF_U1 | usb.USBDF_U2) == 0);
    // On the root port: U2 refused, its timeout back at 0, U1 kept.
    const direct_device = childOf(root, 2).?;
    try testing.expectEqual(d.SelData{ .u1_sel = 10, .u1_pel = 10, .u2_sel = 32, .u2_pel = 32 }, hc.functions[direct].sel);
    try testing.expectEqual(@as(u32, 1), hc.functions[direct].features);
    try testing.expectEqual([2]u8{ 30, 0 }, hc.functions[root_index].timeouts[1]);
    try testing.expectEqual(usb.USBDF_U1, direct_device.public.flags & (usb.USBDF_U1 | usb.USBDF_U2));

    // The stick pulled: its port's timeouts taken back.
    standin.pull(hc, stick);
    _bus.hubsChanged(&rig.bus);
    try testing.expect(childOf(hub_device, 1) == null);
    try testing.expectEqual([2]u8{ 0, 0 }, hc.functions[hub].timeouts[0]);
    try rig.deinit();
}
