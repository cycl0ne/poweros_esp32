// SPDX-License-Identifier: MIT
//! Host tests of a point-to-point network unit (`sdk/devices/network/
//! unit.zig` with `Framing.point_to_point`) and of slip.device's framing
//! (RFC 1055): what the unit says it is, how a frame finds its read by
//! its version, the frames writes become, and the escapes both ways. The
//! serial line itself is proved in the emulator.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const slip = sdk.devices.slip;
const TimeVal = sdk.devices.timer.TimeVal;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const unit_file = sdk.devices.network.unit;
const _slip = @import("../slip/_slip.zig");
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;

const testing = std.testing;

/// A line that sends a write at once into a frame the test can look at.
const Link = struct {
    pub const framing = unit_file.Framing.point_to_point;
    pub const wire_type = net.S2WireType_SLIP;
    pub const mtu: u32 = slip.SLIP_MTU;
    pub const bps: u64 = 115200;

    unit: *TestUnit = undefined,
    running: bool = false,
    frames: [2][slip.SLIP_MTU]u8 = undefined,
    lengths: [2]u32 = @splat(0),
    sent: u32 = 0,

    pub fn setStation(_: *Link, _: *const [6]u8) void {}

    pub fn setRunning(link: *Link, on: bool) void {
        link.running = on;
    }

    pub fn setFilter(_: *Link, _: []const unit_file.Group, _: bool) void {}

    pub fn startWrites(link: *Link) void {
        while (link.unit.nextWrite()) |req| {
            const length = link.unit.buildFrame(req, &link.frames[link.sent]);
            if (length == 0) continue;
            link.lengths[link.sent] = length;
            link.sent += 1;
            link.unit.written(req, true);
        }
    }

    pub fn now(_: *Link) TimeVal {
        return .{};
    }
};

const TestUnit = unit_file.Unit(Link);

fn copyBytes(to: ?*anyopaque, from: ?*const anyopaque, length: u32) callconv(.c) bool {
    const into: [*]u8 = @ptrCast(to.?);
    const out_of: [*]const u8 = @ptrCast(from.?);
    @memcpy(into[0..length], out_of[0..length]);
    return true;
}

fn byteBuffers() [3]TagItem {
    return .{
        .{ .tag = net.S2_CopyToBuff, .data = @intFromPtr(&copyBytes) },
        .{ .tag = net.S2_CopyFromBuff, .data = @intFromPtr(&copyBytes) },
        .{},
    };
}

const no_station: [6]u8 = @splat(0);

/// An opener on `unit`, configured, answering to `port`.
fn openOn(comptime Unit: type, unit: *Unit, port: *exec.MsgPort, tags: []const TagItem, ub: *UtilityBase) !net.IOSana2Req {
    var req: net.IOSana2Req = .{};
    req.req.message.reply_port = port;
    req.req.message.length = @sizeOf(net.IOSana2Req);
    req.buffer_management = @constCast(tags.ptr);
    if (unit.open(&req, 0, ub) != 0) return error.OpenRefused;
    var configure = req;
    configure.req.command = net.S2_CONFIGINTERFACE;
    configure.req.message.node.type = .message;
    unit.perform(&configure);
    _ = kexec.SysBase.iface().GetMsg(port);
    try testing.expectEqual(@as(i8, 0), configure.req.err);
    return req;
}

fn send(comptime Unit: type, unit: *Unit, req: *net.IOSana2Req, command: u16) void {
    req.req.command = command;
    req.req.err = 0;
    req.req.message.node.type = .message;
    unit.perform(req);
}

fn answered(sys: *ExecBase, port: *exec.MsgPort) ?*net.IOSana2Req {
    const message = sys.GetMsg(port) orelse return null;
    return unit_file.requestOf(&message.node);
}

test "a point-to-point unit: no addresses, packets typed by their version, sent as they are" {
    const kub = try utility_library.setUp();
    const ub = kub.iface();
    const sys = kexec.SysBase.iface();
    var link: Link = .{};
    var unit: TestUnit = undefined;
    link.unit = &unit;
    unit.init(sys, &link, &no_station);
    var port: exec.MsgPort = .{ .flags = exec.PA_IGNORE };
    port.msg_list.init(.message);
    const buffers = byteBuffers();
    var opener = try openOn(TestUnit, &unit, &port, &buffers, ub);
    try testing.expect(link.running);

    // What it is.
    var query: net.Sana2DeviceQuery = .{ .size_available = @sizeOf(net.Sana2DeviceQuery) };
    var asked = opener;
    asked.stat_data = &query;
    unit.query(&asked);
    try testing.expectEqual(net.S2WireType_SLIP, query.hardware_type);
    try testing.expectEqual(@as(u32, 0), query.addr_field_size);
    try testing.expectEqual(slip.SLIP_MTU, query.mtu);
    try testing.expectEqual(slip.SLIP_MTU, query.raw_mtu);

    // An IPv4 packet to the IPv4 read, whole; an IPv6 one to the IPv6
    // read; one of another version is damaged.
    var data: [2][64]u8 = @splat(@splat(0));
    var reads: [2]net.IOSana2Req = .{ opener, opener };
    reads[0].packet_type = unit_file.type_ipv4;
    reads[1].packet_type = unit_file.type_ipv6;
    for (&reads, 0..) |*read, index| {
        read.data = &data[index];
        read.data_length = 64;
        send(TestUnit, &unit, read, exec.CMD_READ);
    }
    const six = [_]u8{ 0x60, 0, 0, 0, 0, 0, 59, 64 };
    unit.receive(&six);
    try testing.expectEqual(&reads[1], answered(sys, &port).?);
    try testing.expectEqual(@as(u32, six.len), reads[1].data_length);
    try testing.expectEqualSlices(u8, &six, data[1][0..six.len]);
    const four = [_]u8{ 0x45, 0, 0, 20, 1, 2, 3, 4 };
    unit.receive(&four);
    try testing.expectEqual(&reads[0], answered(sys, &port).?);
    try testing.expectEqualSlices(u8, &four, data[0][0..four.len]);
    try testing.expectEqualSlices(u8, &no_station, reads[0].src_addr[0..6]);
    unit.receive(&[_]u8{ 0x50, 1, 2 });
    try testing.expectEqual(@as(u32, 1), unit.stats.bad_data);

    // A write is the packet as it is; one to a "group" goes too, there
    // being only the other end; one past the MTU is refused.
    var payload: [6]u8 = .{ 0x45, 1, 2, 3, 4, 5 };
    var write = opener;
    write.packet_type = unit_file.type_ipv4;
    write.data = &payload;
    write.data_length = payload.len;
    send(TestUnit, &unit, &write, exec.CMD_WRITE);
    try testing.expectEqual(@as(i8, 0), answered(sys, &port).?.req.err);
    write.dst_addr[0..6].* = .{ 0x01, 0x00, 0x5e, 0, 0, 0xfb };
    send(TestUnit, &unit, &write, net.S2_MULTICAST);
    try testing.expectEqual(@as(i8, 0), answered(sys, &port).?.req.err);
    try testing.expectEqual(@as(u32, 2), link.sent);
    try testing.expectEqualSlices(u8, &payload, link.frames[0][0..link.lengths[0]]);
    write.data_length = slip.SLIP_MTU + 1;
    send(TestUnit, &unit, &write, exec.CMD_WRITE);
    try testing.expectEqual(net.S2ERR_MTU_EXCEEDED, answered(sys, &port).?.req.err);

    unit.close(&opener);
    try utility_library.tearDown(kub);
    kexec.deinit();
}

test "SLIP framing: escapes both ways, packets across reads, a damaged one dropped to its END" {
    const kub = try utility_library.setUp();
    const ub = kub.iface();
    const sys = kexec.SysBase.iface();
    // A line with no serial line under it: the test hands it the bytes.
    const base: *_slip.SlipBase = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(_slip.SlipBase), exec.MEMF_CLEAR).?));
    base.sys_base = sys;
    const line = &base.lines[0];
    line.base = base;
    line.net.init(sys, line, &no_station);
    var port: exec.MsgPort = .{ .flags = exec.PA_IGNORE };
    port.msg_list.init(.message);
    const buffers = byteBuffers();
    var opener = try openOn(_slip.Unit, &line.net, &port, &buffers, ub);

    // Out: END before and after, END and ESC escaped.
    const packet = [_]u8{ 0x45, _slip.end, _slip.esc, 0x01 };
    var encoded: [_slip.encoded_max]u8 = undefined;
    const length = _slip.encode(&packet, &encoded);
    try testing.expectEqualSlices(u8, &.{ 0xC0, 0x45, 0xDB, 0xDC, 0xDB, 0xDD, 0x01, 0xC0 }, encoded[0..length]);

    // In: the same bytes, split across two reads, come back as the
    // packet; an empty one between two ENDs is nothing.
    var data: [3][64]u8 = @splat(@splat(0));
    var reads: [3]net.IOSana2Req = .{ opener, opener, opener };
    for (&reads, 0..) |*read, index| {
        read.packet_type = unit_file.type_ipv4;
        read.data = &data[index];
        read.data_length = 64;
        send(_slip.Unit, &line.net, read, exec.CMD_READ);
    }
    line.decode(encoded[0..3]);
    try testing.expect(answered(sys, &port) == null);
    line.decode(encoded[3..length]);
    try testing.expectEqual(&reads[0], answered(sys, &port).?);
    try testing.expectEqualSlices(u8, &packet, data[0][0..reads[0].data_length]);
    line.decode(&.{ 0xC0, 0xC0 });
    try testing.expect(answered(sys, &port) == null);

    // An ESC before anything but its two: dropped to its END, counted;
    // the next packet is whole again.
    line.decode(&.{ 0x45, 0xDB, 0x41, 0x42, 0xC0, 0x45, 0x07, 0xC0 });
    try testing.expectEqual(@as(u32, 1), line.net.stats.bad_data);
    try testing.expectEqual(&reads[1], answered(sys, &port).?);
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x07 }, data[1][0..reads[1].data_length]);
    // Longer than the MTU: the same.
    var long: [slip.SLIP_MTU + 2]u8 = @splat(0x45);
    long[long.len - 1] = 0xC0;
    line.decode(&long);
    try testing.expectEqual(@as(u32, 2), line.net.stats.bad_data);
    try testing.expect(answered(sys, &port) == null);

    line.net.close(&opener);
    _ = answered(sys, &port);
    sys.FreeVec(base);
    try utility_library.tearDown(kub);
    kexec.deinit();
}
