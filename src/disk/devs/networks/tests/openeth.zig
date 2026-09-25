// SPDX-License-Identifier: MIT
//! Host tests of openeth.device's unit (`openeth/unit.zig`) on a link that
//! is a test's own: which read a frame goes to, orphans, filters, going
//! offline, the frames writes become, groups and aborts. They bring up
//! exec and utility.library from the ROM, so they are here, where only the
//! test build looks. The MAC's registers are not tested here; the
//! emulator is where they are proved.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const TimeVal = sdk.devices.timer.TimeVal;
const TagItem = sdk.utility.TagItem;
const Hook = sdk.utility.Hook;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const unit_file = @import("../openeth/unit.zig");
const ethernet = @import("../openeth/ethernet.zig");
const ethmac = @import("../openeth/ethmac.zig");
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;

const testing = std.testing;

/// A link that keeps what it is told, and sends a write at once into a
/// frame the test can look at - unless it is told to hold them.
const Link = struct {
    pub const bps: u64 = 10_000_000;

    unit: *TestUnit = undefined,
    station: ethernet.Address = @splat(0),
    running: bool = false,
    promiscuous: bool = false,
    groups: u32 = 0,
    hold: bool = false,
    frames: [4][ethernet.frame_max]u8 = undefined,
    lengths: [4]u32 = @splat(0),
    sent: u32 = 0,

    pub fn setStation(link: *Link, address: *const ethernet.Address) void {
        link.station = address.*;
    }

    pub fn setRunning(link: *Link, on: bool) void {
        link.running = on;
    }

    pub fn setFilter(link: *Link, groups: []const unit_file.Group, promiscuous: bool) void {
        link.groups = 0;
        for (groups) |joined| {
            if (joined.users != 0) link.groups += 1;
        }
        link.promiscuous = promiscuous;
    }

    pub fn startWrites(link: *Link) void {
        if (link.hold) return;
        while (link.unit.nextWrite()) |req| {
            const length = link.unit.buildFrame(req, &link.frames[link.sent]);
            if (length == 0) continue;
            link.lengths[link.sent] = length;
            link.sent += 1;
            link.unit.written(req, true);
        }
    }

    pub fn now(_: *Link) TimeVal {
        return .{ .secs = 42 };
    }
};

const TestUnit = unit_file.Unit(Link);

fn copyBytes(to: ?*anyopaque, from: ?*const anyopaque, length: u32) callconv(.c) bool {
    const into: [*]u8 = @ptrCast(to.?);
    const out_of: [*]const u8 = @ptrCast(from.?);
    @memcpy(into[0..length], out_of[0..length]);
    return true;
}

fn copyNothing(_: ?*anyopaque, _: ?*const anyopaque, _: u32) callconv(.c) bool {
    return false;
}

/// The tag list of an opener whose buffers are plain bytes. A function's
/// address is known only once the test is linked, so it is made at run
/// time.
fn byteBuffers() [3]TagItem {
    return .{
        .{ .tag = net.S2_CopyToBuff, .data = @intFromPtr(&copyBytes) },
        .{ .tag = net.S2_CopyFromBuff, .data = @intFromPtr(&copyBytes) },
        .{},
    };
}

const station: ethernet.Address = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
const peer: ethernet.Address = .{ 0x52, 0x55, 0x0A, 0x00, 0x02, 0x02 };
const group: ethernet.Address = .{ 0x01, 0x00, 0x5E, 0x00, 0x00, 0xFB };

/// exec and utility.library, a unit on a test link, and a port every
/// request is answered to.
const Rig = struct {
    kub: *utility_library.UtilityBase,
    ub: *UtilityBase,
    sys: *ExecBase,
    link: Link,
    unit: TestUnit,
    port: exec.MsgPort,

    fn init(rig: *Rig) !void {
        rig.kub = try utility_library.setUp();
        rig.ub = rig.kub.iface();
        rig.sys = kexec.SysBase.iface();
        rig.link = .{};
        rig.link.unit = &rig.unit;
        rig.unit.init(rig.sys, &rig.link, &station);
        rig.port = .{ .flags = exec.PA_IGNORE };
        rig.port.msg_list.init(.message);
    }

    fn deinit(rig: *Rig) !void {
        try utility_library.tearDown(rig.kub);
        kexec.deinit();
    }

    /// An opener with `tags`, and the request it opened with.
    fn open(rig: *Rig, tags: []const TagItem, flags: u32) !net.IOSana2Req {
        var req: net.IOSana2Req = .{};
        req.req.message.reply_port = &rig.port;
        req.req.message.length = @sizeOf(net.IOSana2Req);
        req.buffer_management = @constCast(tags.ptr);
        const refused = rig.unit.open(&req, flags, rig.ub);
        if (refused != 0) return error.OpenRefused;
        return req;
    }

    /// `req` sent with `command`, as BeginIO would hand it to the task.
    fn send(rig: *Rig, req: *net.IOSana2Req, command: u16) void {
        req.req.command = command;
        req.req.err = 0;
        req.req.message.node.type = .message;
        rig.unit.perform(req);
    }

    /// The next answered request, or null.
    fn answered(rig: *Rig) ?*net.IOSana2Req {
        const message = rig.sys.GetMsg(&rig.port) orelse return null;
        return unit_file.requestOf(&message.node);
    }

    fn configure(rig: *Rig, opener: *net.IOSana2Req) !void {
        var req = opener.*;
        req.src_addr[0..6].* = station;
        rig.send(&req, net.S2_CONFIGINTERFACE);
        try testing.expectEqual(&req, rig.answered().?);
        try testing.expectEqual(@as(i8, 0), req.req.err);
    }
};

/// An ARP frame, from `peer` to every station.
fn arpFrame() [ethernet.header_bytes + 28]u8 {
    var frame: [ethernet.header_bytes + 28]u8 = @splat(0xA5);
    ethernet.write(&frame, &ethernet.broadcast, &peer, 0x0806);
    return frame;
}

test "a frame goes to the first read of its type of every opener" {
    var rig: Rig = undefined;
    try rig.init();
    const buffers = byteBuffers();
    var first = try rig.open(&buffers, 0);
    var second = try rig.open(&buffers, 0);
    try rig.configure(&first);
    try testing.expect(rig.link.running);
    try testing.expectEqual(station, rig.link.station);

    var data: [4][64]u8 = @splat(@splat(0));
    var reads: [4]net.IOSana2Req = .{ first, first, first, second };
    const types = [4]u32{ 0x0806, 0x0806, 0x0800, 0x0806 };
    for (&reads, 0..) |*read, i| {
        read.packet_type = types[i];
        read.data = &data[i];
        read.data_length = 64;
        rig.send(read, exec.CMD_READ);
    }
    try testing.expectEqual(null, rig.answered());

    const frame = arpFrame();
    rig.unit.receive(&frame);
    try testing.expectEqual(&reads[0], rig.answered().?);
    try testing.expectEqual(&reads[3], rig.answered().?);
    try testing.expectEqual(null, rig.answered());
    try testing.expectEqual(@as(u32, 28), reads[0].data_length);
    try testing.expectEqual(net.SANA2IOF_BCAST, reads[0].req.flags & net.SANA2IOF_BCAST);
    try testing.expectEqualSlices(u8, &peer, reads[0].src_addr[0..6]);
    try testing.expectEqualSlices(u8, frame[ethernet.header_bytes..], data[0][0..28]);
    try testing.expectEqual(@as(u64, 1), rig.unit.stats.packets_received);

    rig.unit.close(&first);
    try testing.expectEqual(&reads[1], rig.answered().?);
    try testing.expectEqual(exec.IOERR_ABORTED, reads[1].req.err);
    try testing.expectEqual(&reads[2], rig.answered().?);
    rig.unit.close(&second);
    try rig.deinit();
}

test "a frame no read wants goes to an orphan read, else it is counted" {
    var rig: Rig = undefined;
    try rig.init();
    const buffers = byteBuffers();
    var opener = try rig.open(&buffers, 0);
    try rig.configure(&opener);
    var data: [64]u8 = undefined;
    var orphan = opener;
    orphan.data = &data;
    orphan.data_length = data.len;
    orphan.req.flags = net.SANA2IOF_RAW;
    rig.send(&orphan, net.S2_READORPHAN);

    var frame = arpFrame();
    ethernet.write(&frame, &station, &peer, 0x86DD);
    rig.unit.receive(&frame);
    try testing.expectEqual(&orphan, rig.answered().?);
    try testing.expectEqual(@as(u32, 0x86DD), orphan.packet_type);
    try testing.expectEqual(@as(u32, frame.len), orphan.data_length);
    try testing.expectEqual(@as(u8, 0), orphan.req.flags & (net.SANA2IOF_BCAST | net.SANA2IOF_MCAST));
    try testing.expectEqualSlices(u8, &frame, data[0..frame.len]);

    rig.unit.receive(&frame);
    try testing.expectEqual(null, rig.answered());
    try testing.expectEqual(@as(u64, 1), rig.unit.stats.unknown_types_received);
    rig.unit.close(&opener);
    try rig.deinit();
}

/// A filter that leaves every frame to reads other than the one whose
/// data is its hook's.
fn refuseOne(hook: *Hook, object: ?*anyopaque, _: ?*anyopaque) callconv(.c) usize {
    const req: *net.IOSana2Req = @ptrCast(@alignCast(object.?));
    return @intFromBool(req.data != hook.data);
}

test "a read the filter refuses leaves the frame to the next one" {
    var rig: Rig = undefined;
    try rig.init();
    const buffers = byteBuffers();
    var refused: [64]u8 = undefined;
    var taken: [64]u8 = undefined;
    var hook: Hook = .{ .entry = &refuseOne, .data = &refused };
    const tags = [_]TagItem{
        buffers[0],
        buffers[1],
        .{ .tag = net.S2_PacketFilter, .data = @intFromPtr(&hook) },
        .{},
    };
    var opener = try rig.open(&tags, 0);
    try rig.configure(&opener);
    var reads: [2]net.IOSana2Req = .{ opener, opener };
    reads[0].data = &refused;
    reads[1].data = &taken;
    for (&reads) |*read| {
        read.packet_type = 0x0806;
        read.data_length = 64;
        rig.send(read, exec.CMD_READ);
    }
    const frame = arpFrame();
    rig.unit.receive(&frame);
    try testing.expectEqual(&reads[1], rig.answered().?);
    try testing.expectEqual(null, rig.answered());
    rig.unit.close(&opener);
    try testing.expectEqual(&reads[0], rig.answered().?);
    try rig.deinit();
}

test "going offline answers the reads and writes, and the events waiting for it" {
    var rig: Rig = undefined;
    try rig.init();
    const buffers = byteBuffers();
    var opener = try rig.open(&buffers, 0);
    var read = opener;
    rig.send(&read, exec.CMD_READ);
    try testing.expectEqual(&read, rig.answered().?);
    try testing.expectEqual(net.S2ERR_OUTOFSERVICE, read.req.err);
    try testing.expectEqual(net.S2WERR_NOT_CONFIGURED, read.wire_error);

    try rig.configure(&opener);
    try testing.expectEqual(@as(u32, 42), rig.unit.stats.last_start.secs);
    rig.link.hold = true;
    var payload: [10]u8 = @splat(1);
    var write = opener;
    write.data = &payload;
    write.data_length = payload.len;
    read.data = &payload;
    read.data_length = payload.len;
    var event = opener;
    event.wire_error = net.S2EVENT_OFFLINE | net.S2EVENT_ERROR;
    rig.send(&read, exec.CMD_READ);
    rig.send(&write, exec.CMD_WRITE);
    rig.send(&event, net.S2_ONEVENT);
    try testing.expectEqual(null, rig.answered());

    var offline = opener;
    rig.send(&offline, net.S2_OFFLINE);
    try testing.expect(!rig.link.running);
    var seen: u32 = 0;
    while (rig.answered()) |req| {
        seen += 1;
        if (req == &event) {
            try testing.expectEqual(net.S2EVENT_OFFLINE, event.wire_error);
        } else if (req != &offline) {
            try testing.expectEqual(net.S2ERR_OUTOFSERVICE, req.req.err);
            try testing.expectEqual(net.S2WERR_UNIT_OFFLINE, req.wire_error);
        }
    }
    try testing.expectEqual(@as(u32, 4), seen);

    // An event for a state that holds is answered at once.
    event.wire_error = net.S2EVENT_OFFLINE;
    rig.send(&event, net.S2_ONEVENT);
    try testing.expectEqual(&event, rig.answered().?);
    rig.unit.close(&opener);
    try rig.deinit();
}

test "a write becomes a frame from the station, and a broadcast one to every station" {
    var rig: Rig = undefined;
    try rig.init();
    const buffers = byteBuffers();
    var opener = try rig.open(&buffers, 0);
    try rig.configure(&opener);
    var payload: [10]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    var write = opener;
    write.dst_addr[0..6].* = peer;
    write.packet_type = 0x0800;
    write.data = &payload;
    write.data_length = payload.len;
    rig.send(&write, exec.CMD_WRITE);
    try testing.expectEqual(&write, rig.answered().?);
    try testing.expectEqual(@as(i8, 0), write.req.err);
    rig.send(&write, net.S2_BROADCAST);
    try testing.expectEqual(&write, rig.answered().?);

    try testing.expectEqual(@as(u32, 2), rig.link.sent);
    const unicast = rig.link.frames[0][0..rig.link.lengths[0]];
    try testing.expectEqual(@as(usize, ethernet.header_bytes + payload.len), unicast.len);
    const header = ethernet.parse(unicast).?;
    try testing.expectEqual(peer, header.dst);
    try testing.expectEqual(station, header.src);
    try testing.expectEqual(@as(u16, 0x0800), header.type);
    try testing.expectEqualSlices(u8, &payload, unicast[ethernet.header_bytes..]);
    try testing.expectEqual(ethernet.broadcast, ethernet.parse(&rig.link.frames[1]).?.dst);
    try testing.expectEqual(@as(u64, 2), rig.unit.stats.packets_sent);

    // Too long, and a copy call that fails.
    write.data_length = ethernet.mtu + 1;
    rig.send(&write, exec.CMD_WRITE);
    try testing.expectEqual(net.S2ERR_MTU_EXCEEDED, rig.answered().?.req.err);
    rig.unit.close(&opener);

    const failing = [_]TagItem{ buffers[0], .{ .tag = net.S2_CopyFromBuff, .data = @intFromPtr(&copyNothing) }, .{} };
    var other = try rig.open(&failing, 0);
    var broken = other;
    broken.data = &payload;
    broken.data_length = payload.len;
    rig.send(&broken, exec.CMD_WRITE);
    try testing.expectEqual(&broken, rig.answered().?);
    try testing.expectEqual(net.S2ERR_NO_RESOURCES, broken.req.err);
    try testing.expectEqual(net.S2WERR_BUFF_ERROR, broken.wire_error);
    rig.unit.close(&other);
    try rig.deinit();
}

test "a frame to a group is taken only once the unit has joined it" {
    var rig: Rig = undefined;
    try rig.init();
    const buffers = byteBuffers();
    var opener = try rig.open(&buffers, 0);
    try rig.configure(&opener);
    var data: [64]u8 = undefined;
    var read = opener;
    read.packet_type = 0x0800;
    read.data = &data;
    read.data_length = data.len;
    rig.send(&read, exec.CMD_READ);
    var frame = arpFrame();
    ethernet.write(&frame, &group, &peer, 0x0800);
    rig.unit.receive(&frame);
    try testing.expectEqual(null, rig.answered());

    var join = opener;
    join.src_addr[0..6].* = group;
    rig.send(&join, net.S2_ADDMULTICASTADDRESS);
    try testing.expectEqual(@as(i8, 0), rig.answered().?.req.err);
    rig.send(&join, net.S2_ADDMULTICASTADDRESS);
    _ = rig.answered();
    try testing.expectEqual(@as(u32, 1), rig.link.groups);
    rig.unit.receive(&frame);
    try testing.expectEqual(&read, rig.answered().?);
    try testing.expectEqual(net.SANA2IOF_MCAST, read.req.flags & net.SANA2IOF_MCAST);

    // Added twice, so it takes two deletes to leave.
    rig.send(&join, net.S2_DELMULTICASTADDRESS);
    _ = rig.answered();
    try testing.expectEqual(@as(u32, 1), rig.link.groups);
    rig.send(&join, net.S2_DELMULTICASTADDRESS);
    _ = rig.answered();
    try testing.expectEqual(@as(u32, 0), rig.link.groups);
    join.src_addr[0..6].* = station;
    rig.send(&join, net.S2_ADDMULTICASTADDRESS);
    try testing.expectEqual(net.S2ERR_BAD_ADDRESS, rig.answered().?.req.err);
    rig.unit.close(&opener);
    try rig.deinit();
}

test "an abort takes a waiting read back once, and a unit taken alone refuses others" {
    var rig: Rig = undefined;
    try rig.init();
    const buffers = byteBuffers();
    var opener = try rig.open(&buffers, net.SANA2OPF_MINE);
    try testing.expectError(error.OpenRefused, rig.open(&buffers, 0));
    try rig.configure(&opener);
    var read = opener;
    rig.send(&read, exec.CMD_READ);
    try testing.expect(rig.unit.abort(&read));
    try testing.expectEqual(&read, rig.answered().?);
    try testing.expectEqual(exec.IOERR_ABORTED, read.req.err);
    try testing.expect(!rig.unit.abort(&read));
    rig.unit.close(&opener);
    var again = try rig.open(&buffers, 0);
    rig.unit.close(&again);
    try rig.deinit();
}

test "the MAC's group hash is the top six bits of the address's CRC" {
    try testing.expectEqual(@as(u6, 31), ethmac.groupHash(&.{ 0x01, 0x00, 0x5E, 0x00, 0x00, 0x01 }));
    try testing.expectEqual(@as(u6, 62), ethmac.groupHash(&.{ 0x33, 0x33, 0x00, 0x00, 0x00, 0x01 }));
    try testing.expectEqual(@as(u6, 15), ethmac.groupHash(&group));
}
