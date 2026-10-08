// SPDX-License-Identifier: MIT
//! Host tests of IPv4 groups and IGMP, on an Ethernet link the test
//! watches: every IPv4 frame the stack sends is recorded with the station
//! it went to, and what the network says - queries, datagrams to a group -
//! is written by the test. Time is the test's to say.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const bsdsocket = @import("../bsdsocket_init.zig");
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _ip = @import("../ip/_ip.zig");
const _igmp = @import("../igmp/_igmp.zig");
const _route = @import("../route/_route.zig");
const _arp = @import("../arp/_arp.zig");
const _timer = @import("../timer/_timer.zig");
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;

const testing = std.testing;

const Sent = struct {
    to: [6]u8,
    bytes: [256]u8,
    length: usize,

    fn headerLength(entry: *const Sent) usize {
        return @as(usize, entry.bytes[0] & 0xF) * 4;
    }

    fn ttl(entry: *const Sent) u8 {
        return entry.bytes[8];
    }

    fn protocol(entry: *const Sent) u8 {
        return entry.bytes[9];
    }

    fn destination(entry: *const Sent) u32 {
        return _ip.get32(&entry.bytes, 16);
    }

    /// What the IPv4 header carries.
    fn message(entry: *const Sent) []const u8 {
        return entry.bytes[entry.headerLength()..entry.length];
    }

    fn kind(entry: *const Sent) u8 {
        return if (entry.protocol() == _igmp.protocol) entry.message()[0] else 0;
    }

    fn checksumsRight(entry: *const Sent) bool {
        return _ip.finish(_ip.sum(0, entry.bytes[0..entry.headerLength()])) == 0 and _ip.finish(_ip.sum(0, entry.message())) == 0;
    }

    /// Whether the IGMPv3 report holds a record of `record_type` for
    /// `group`.
    fn records(entry: *const Sent, record_type: u8, group: u32) bool {
        const body = entry.message();
        var at: usize = 8;
        for (0.._ip.get16(body, 6)) |_| {
            if (body[at] == record_type and _ip.get32(body, at + 4) == group) return true;
            at += 8 + 4 * @as(usize, _ip.get16(body, at + 2));
        }
        return false;
    }
};

var sent: [32]Sent = undefined;
var sent_count: usize = 0;

fn capture(stack: *StackBase, _: *Interface, frame: *Frame, to: *const [6]u8, packet_type: u16) i32 {
    const bytes = frame.bytes();
    if (packet_type == _ip.ethertype and sent_count < sent.len) {
        sent[sent_count] = .{ .to = to.*, .bytes = undefined, .length = @min(bytes.len, 256) };
        @memcpy(sent[sent_count].bytes[0..sent[sent_count].length], bytes[0..sent[sent_count].length]);
        sent_count += 1;
    }
    stack.frames.give(stack.sys_base, frame);
    return 0;
}

const own_hardware = [6]u8{ 0x02, 0, 0, 0, 0, 1 };
const peer_hardware = [6]u8{ 0x02, 0, 0, 0, 0, 2 };
const own: u32 = 0x0A00_0002;
const peer: u32 = 0x0A00_0001;
/// 224.0.0.251, mDNS's group.
const mdns: u32 = 0xE000_00FB;
const mdns_station = [6]u8{ 0x01, 0x00, 0x5e, 0, 0, 0xfb };

const Rig = struct {
    kub: *utility_library.UtilityBase,
    stack_lib: *exec.Library,
    sb: *SocketBase,
    stack: *StackBase,
    interface: *Interface,

    /// The stack with an interface on the watched link, IGMP started.
    fn init() !Rig {
        const kub = try utility_library.setUp();
        const sys = kexec.SysBase.iface();
        const made = kexec.InitResident(kexec.SysBase, &bsdsocket.bsdsocket_library_tag, null) orelse return error.NoLibrary;
        const stack_lib: *exec.Library = @ptrCast(@alignCast(made));
        const sb: *SocketBase = @ptrCast(sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse return error.NoBase);
        const stack = _base.stackBase(stack_lib);
        stack.no_task = 1;
        stack.fixed_time = 1_000_000;
        const interface = _netif.free(stack).?;
        interface.* = .{
            .address = own,
            .netmask = 0xFFFF_FF00,
            .broadcast = 0x0A00_00FF,
            .mtu = 1500,
            .used = 1,
            .up = 1,
            .hardware = own_hardware,
            .transmit = &capture,
        };
        @memcpy(interface.name[0..4], "test");
        _ = _route.add(stack, own, 0xFFFF_FF00, 0, interface);
        _igmp.start(stack, interface);
        sent_count = 0;
        return .{ .kub = kub, .stack_lib = stack_lib, .sb = sb, .stack = stack, .interface = interface };
    }

    fn deinit(rig: *Rig) !void {
        const sys = kexec.SysBase.iface();
        _igmp.stop(rig.stack, rig.interface);
        _arp.forget(rig.stack, rig.interface);
        _route.removeAll(rig.stack, rig.interface);
        rig.interface.* = .{};
        sys.CloseLibrary(rig.sb.lib());
        _ = sys.RemLibrary(rig.stack_lib);
        try utility_library.tearDown(rig.kub);
        kexec.deinit();
    }

    fn pass(rig: *Rig, us: u64) void {
        const end = rig.stack.fixed_time + us;
        while (rig.stack.fixed_time < end) {
            rig.stack.fixed_time = @min(end, rig.stack.fixed_time + 100_000);
            _timer.run(rig.stack, rig.stack.fixed_time);
        }
    }

    /// An IPv4 packet from the network to `destination` with `ttl`, its
    /// checksums made: an IGMP message's, a UDP datagram's left as given.
    fn arrive(rig: *Rig, source: u32, destination: u32, protocol: u8, ttl: u8, body: []const u8) void {
        const frame = rig.stack.frames.take(rig.stack.sys_base).?;
        const packet = frame.buffer[frame.start..][0 .. _ip.header_bytes + body.len];
        frame.length = @intCast(packet.len);
        @memset(packet[0.._ip.header_bytes], 0);
        packet[0] = 0x45;
        _ip.put16(packet, 2, @intCast(packet.len));
        packet[8] = ttl;
        packet[9] = protocol;
        _ip.put32(packet, 12, source);
        _ip.put32(packet, 16, destination);
        _ip.put16(packet, 10, _ip.finish(_ip.sum(0, packet[0.._ip.header_bytes])));
        const message = packet[_ip.header_bytes..];
        @memcpy(message, body);
        if (protocol == _igmp.protocol) {
            _ip.put16(message, 2, 0);
            _ip.put16(message, 2, _ip.finish(_ip.sum(0, message)));
        }
        const station = if (_igmp.isGroup(destination)) _igmp.groupStation(destination) else own_hardware;
        _netif.receive(rig.stack, rig.interface, frame, &peer_hardware, &station, _ip.ethertype, rig.stack.fixed_time);
    }

    /// A query of `length` bytes (8 for IGMPv1 and IGMPv2, 12 for IGMPv3)
    /// for `group` (0 for all), with the response code `code`.
    fn query(rig: *Rig, group: u32, code: u8, length: usize) void {
        var body: [12]u8 = @splat(0);
        body[0] = _igmp.query;
        body[1] = code;
        _ip.put32(&body, 4, group);
        rig.arrive(peer, if (group == 0) _igmp.all_hosts else group, _igmp.protocol, 1, body[0..length]);
    }

    /// A UDP datagram from the peer to `group`:5353.
    fn toGroup(rig: *Rig, group: u32, text: []const u8) void {
        var body: [64]u8 = undefined;
        const datagram = body[0 .. 8 + text.len];
        _ip.put16(datagram, 0, 5353);
        _ip.put16(datagram, 2, 5353);
        _ip.put16(datagram, 4, @intCast(datagram.len));
        _ip.put16(datagram, 6, 0);
        @memcpy(datagram[8..], text);
        _ip.put16(datagram, 6, _ip.finish(_ip.sum(_ip.pseudoSum(peer, group, @intCast(bsd.IPPROTO_UDP), @intCast(datagram.len)), datagram)));
        rig.arrive(peer, group, @intCast(bsd.IPPROTO_UDP), 255, datagram);
    }
};

fn count(kind: u8) usize {
    var found: usize = 0;
    for (sent[0..sent_count]) |*entry| {
        if (entry.kind() == kind) found += 1;
    }
    return found;
}

fn find(kind: u8) ?*const Sent {
    for (sent[0..sent_count]) |*entry| {
        if (entry.kind() == kind) return entry;
    }
    return null;
}

/// A datagram socket of `family` on port 5353, in `group` on the route's
/// interface.
fn groupSocket(rig: *Rig, family: i32, group: u32) !i32 {
    const sb = rig.sb;
    const socket = sb.Socket(family, bsd.SOCK_DGRAM, 0);
    if (socket < 0) return error.NoSocket;
    _ = sb.IoctlSocket(socket, bsd.FIONBIO, @constCast(&@as(u32, 1)));
    const on: i32 = 1;
    _ = sb.SetSockOpt(socket, bsd.SOL_SOCKET, bsd.SO_REUSEADDR, &on, @sizeOf(i32));
    if (family == bsd.PF_INET) {
        var here: bsd.sockaddr_in = .{ .sin_port = bsd.htons(5353) };
        try testing.expectEqual(@as(i32, 0), sb.Bind(socket, here.anyConst(), @sizeOf(bsd.sockaddr_in)));
    } else {
        var here: bsd.sockaddr_in6 = .{ .sin6_port = bsd.htons(5353) };
        try testing.expectEqual(@as(i32, 0), sb.Bind(socket, here.anyConst(), @sizeOf(bsd.sockaddr_in6)));
    }
    const request: bsd.ip_mreq = .{ .imr_multiaddr = .{ .s_addr = bsd.htonl(group) } };
    try testing.expectEqual(@as(i32, 0), sb.SetSockOpt(socket, bsd.IPPROTO_IP, bsd.IP_ADD_MEMBERSHIP, &request, @sizeOf(bsd.ip_mreq)));
    return socket;
}

test "a group joined is reported twice as IGMPv3, and left the same way" {
    var rig = try Rig.init();
    const socket = try groupSocket(&rig, bsd.PF_INET, mdns);
    try testing.expect(_igmp.isOurs(rig.interface, mdns));
    rig.pass(3_000_000);
    try testing.expectEqual(@as(usize, 2), count(_igmp.report));
    const first = find(_igmp.report).?;
    try testing.expect(first.checksumsRight());
    // To every IGMPv3 router, on its own station, with a time to live of
    // 1, the router alert and internetwork control.
    try testing.expectEqual(_igmp.all_routers_v3, first.destination());
    try testing.expectEqual([6]u8{ 0x01, 0x00, 0x5e, 0, 0, 0x16 }, first.to);
    try testing.expectEqual(@as(u8, 1), first.ttl());
    try testing.expectEqual(@as(usize, 24), first.headerLength());
    try testing.expectEqualSlices(u8, &.{ 0x94, 0x04, 0, 0 }, first.bytes[20..24]);
    try testing.expectEqual(@as(u8, 0xC0), first.bytes[1]);
    try testing.expectEqual(own, _ip.get32(&first.bytes, 12));
    try testing.expect(first.records(_igmp.to_exclude, mdns));
    // All hosts is in no report.
    try testing.expect(!first.records(_igmp.to_exclude, _igmp.all_hosts));
    try testing.expect(_igmp.isOurs(rig.interface, _igmp.all_hosts));

    // Closed: the group is left, and that said twice.
    sent_count = 0;
    _ = rig.sb.CloseSocket(socket);
    try testing.expect(!_igmp.isOurs(rig.interface, mdns));
    rig.pass(3_000_000);
    try testing.expectEqual(@as(usize, 2), count(_igmp.report));
    try testing.expect(find(_igmp.report).?.records(_igmp.to_include, mdns));
    // Then quiet.
    sent_count = 0;
    rig.pass(5_000_000);
    try testing.expectEqual(@as(usize, 0), sent_count);
    try rig.deinit();
}

test "queries are answered, and older queriers get their own version" {
    var rig = try Rig.init();
    const socket = try groupSocket(&rig, bsd.PF_INET, mdns);
    rig.pass(3_000_000);

    // A general IGMPv3 query with a second to answer in.
    sent_count = 0;
    rig.query(0, 10, 12);
    rig.pass(1_100_000);
    try testing.expectEqual(@as(usize, 1), count(_igmp.report));
    try testing.expect(find(_igmp.report).?.records(_igmp.mode_is_exclude, mdns));
    // One for a group not joined: nothing.
    sent_count = 0;
    rig.query(0xE000_00FC, 10, 12);
    rig.pass(1_100_000);
    try testing.expectEqual(@as(usize, 0), sent_count);
    // A response code with an exponent: 0x8A is (0x1A << 3) tenths, 20.8
    // seconds, and nothing before the answer's random time.
    rig.query(mdns, 0x8A, 12);
    rig.pass(21_000_000);
    try testing.expectEqual(@as(usize, 1), count(_igmp.report));

    // An IGMPv2 query: an IGMPv2 report, to the group itself.
    sent_count = 0;
    rig.query(0, 10, 8);
    rig.pass(1_100_000);
    try testing.expectEqual(@as(usize, 0), count(_igmp.report));
    const v2 = find(_igmp.report_v2).?;
    try testing.expect(v2.checksumsRight());
    try testing.expectEqual(mdns, v2.destination());
    try testing.expectEqual(mdns_station, v2.to);
    try testing.expectEqual(mdns, _ip.get32(v2.message(), 4));
    // Left while it is there: an IGMPv2 leave to all routers.
    sent_count = 0;
    _ = rig.sb.CloseSocket(socket);
    rig.pass(3_000_000);
    const leave = find(_igmp.leave_v2).?;
    try testing.expectEqual(_igmp.all_routers, leave.destination());
    try testing.expectEqual(mdns, _ip.get32(leave.message(), 4));

    // An IGMPv1 query: IGMPv1 reports, and a group left is not told.
    const again = try groupSocket(&rig, bsd.PF_INET, mdns);
    rig.query(0, 0, 8);
    sent_count = 0;
    rig.pass(10_100_000);
    try testing.expect(count(_igmp.report_v1) >= 1);
    try testing.expectEqual(@as(usize, 0), count(_igmp.report_v2));
    sent_count = 0;
    _ = rig.sb.CloseSocket(again);
    rig.pass(3_000_000);
    try testing.expectEqual(@as(usize, 0), sent_count);

    // Once the older queriers are long gone, IGMPv3 again.
    rig.pass(_igmp.older_present_us);
    const third = try groupSocket(&rig, bsd.PF_INET, mdns);
    sent_count = 0;
    rig.pass(3_000_000);
    try testing.expectEqual(@as(usize, 2), count(_igmp.report));
    _ = rig.sb.CloseSocket(third);
    rig.pass(3_000_000);
    try rig.deinit();
}

test "datagrams to a group: each member takes one; sent once, looped back" {
    var rig = try Rig.init();
    const sb = rig.sb;
    const one = try groupSocket(&rig, bsd.PF_INET, mdns);
    // An IPv6 socket that speaks IPv4 too.
    const two = try groupSocket(&rig, bsd.PF_INET6, mdns);
    // In no group, on the same port: nothing for it.
    const outside = rig.sb.Socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    _ = sb.IoctlSocket(outside, bsd.FIONBIO, @constCast(&@as(u32, 1)));
    const on: i32 = 1;
    _ = sb.SetSockOpt(outside, bsd.SOL_SOCKET, bsd.SO_REUSEADDR, &on, @sizeOf(i32));
    var here: bsd.sockaddr_in = .{ .sin_port = bsd.htons(5353) };
    try testing.expectEqual(@as(i32, 0), sb.Bind(outside, here.anyConst(), @sizeOf(bsd.sockaddr_in)));
    // Joined twice: refused.
    const request: bsd.ip_mreq = .{ .imr_multiaddr = .{ .s_addr = bsd.htonl(mdns) }, .imr_interface = .{ .s_addr = bsd.htonl(own) } };
    try testing.expectEqual(@as(i32, -1), sb.SetSockOpt(one, bsd.IPPROTO_IP, bsd.IP_ADD_MEMBERSHIP, &request, @sizeOf(bsd.ip_mreq)));
    try testing.expectEqual(bsd.EADDRINUSE, sb.Errno());
    // No group: refused.
    const unicast: bsd.ip_mreq = .{ .imr_multiaddr = .{ .s_addr = bsd.htonl(peer) } };
    try testing.expectEqual(@as(i32, -1), sb.SetSockOpt(outside, bsd.IPPROTO_IP, bsd.IP_ADD_MEMBERSHIP, &unicast, @sizeOf(bsd.ip_mreq)));
    try testing.expectEqual(bsd.EINVAL, sb.Errno());

    rig.toGroup(mdns, "hello");
    var buffer: [64]u8 = undefined;
    var from: bsd.sockaddr_in = .{};
    var from_length: u32 = @sizeOf(bsd.sockaddr_in);
    try testing.expectEqual(@as(i32, 5), sb.RecvFrom(one, &buffer, buffer.len, 0, from.any(), &from_length));
    try testing.expectEqual(peer, bsd.ntohl(from.sin_addr.s_addr));
    try testing.expectEqual(@as(i32, 5), sb.Recv(two, &buffer, buffer.len, 0));
    try testing.expectEqual(@as(i32, -1), sb.Recv(outside, &buffer, buffer.len, 0));
    // To a group not joined: dropped before UDP.
    const not_ours = rig.stack.counts.ip_not_ours;
    rig.toGroup(0xE000_00FC, "hello");
    try testing.expectEqual(not_ours + 1, rig.stack.counts.ip_not_ours);

    // Sent to the group: once on the link to its station, a time to live
    // of 1, and a copy for each member here.
    rig.pass(3_000_000);
    sent_count = 0;
    var to: bsd.sockaddr_in = .{ .sin_port = bsd.htons(5353), .sin_addr = .{ .s_addr = bsd.htonl(mdns) } };
    try testing.expectEqual(@as(i32, 3), sb.SendTo(outside, "ask", 3, 0, to.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(@as(usize, 1), sent_count);
    try testing.expectEqual(mdns_station, sent[0].to);
    try testing.expectEqual(@as(u8, 1), sent[0].ttl());
    try testing.expectEqual(@as(usize, 20), sent[0].headerLength());
    try testing.expect(_ip.finish(_ip.sum(0, sent[0].bytes[0..20])) == 0);
    try testing.expectEqual(@as(i32, 3), sb.Recv(one, &buffer, buffer.len, 0));
    try testing.expectEqual(@as(i32, 3), sb.Recv(two, &buffer, buffer.len, 0));
    try testing.expectEqual(@as(i32, -1), sb.Recv(outside, &buffer, buffer.len, 0));

    // A time to live as a u8, and the loop off as an i32: no copy.
    const ttl: u8 = 32;
    try testing.expectEqual(@as(i32, 0), sb.SetSockOpt(outside, bsd.IPPROTO_IP, bsd.IP_MULTICAST_TTL, &ttl, 1));
    const off: i32 = 0;
    try testing.expectEqual(@as(i32, 0), sb.SetSockOpt(outside, bsd.IPPROTO_IP, bsd.IP_MULTICAST_LOOP, &off, @sizeOf(i32)));
    var read_ttl: i32 = 0;
    var size: u32 = @sizeOf(i32);
    try testing.expectEqual(@as(i32, 0), sb.GetSockOpt(outside, bsd.IPPROTO_IP, bsd.IP_MULTICAST_TTL, &read_ttl, &size));
    try testing.expectEqual(@as(i32, 32), read_ttl);
    var read_loop: u8 = 9;
    size = 1;
    try testing.expectEqual(@as(i32, 0), sb.GetSockOpt(outside, bsd.IPPROTO_IP, bsd.IP_MULTICAST_LOOP, &read_loop, &size));
    try testing.expectEqual(@as(u8, 0), read_loop);
    try testing.expectEqual(@as(u32, 1), size);
    _ = sb.SendTo(outside, "ask", 3, 0, to.anyConst(), @sizeOf(bsd.sockaddr_in));
    try testing.expectEqual(@as(u8, 32), sent[1].ttl());
    try testing.expectEqual(@as(i32, -1), sb.Recv(one, &buffer, buffer.len, 0));

    // The interface named by its address, and read back.
    const named: bsd.in_addr = .{ .s_addr = bsd.htonl(own) };
    try testing.expectEqual(@as(i32, 0), sb.SetSockOpt(outside, bsd.IPPROTO_IP, bsd.IP_MULTICAST_IF, &named, @sizeOf(bsd.in_addr)));
    var read_if: bsd.in_addr = .{};
    size = @sizeOf(bsd.in_addr);
    try testing.expectEqual(@as(i32, 0), sb.GetSockOpt(outside, bsd.IPPROTO_IP, bsd.IP_MULTICAST_IF, &read_if, &size));
    try testing.expectEqual(own, bsd.ntohl(read_if.s_addr));
    const nobody: bsd.in_addr = .{ .s_addr = bsd.htonl(0x0A00_0063) };
    try testing.expectEqual(@as(i32, -1), sb.SetSockOpt(outside, bsd.IPPROTO_IP, bsd.IP_MULTICAST_IF, &nobody, @sizeOf(bsd.in_addr)));
    try testing.expectEqual(bsd.EADDRNOTAVAIL, sb.Errno());

    // One leaves: still in the group through the other; dropped twice:
    // refused.
    try testing.expectEqual(@as(i32, 0), sb.SetSockOpt(one, bsd.IPPROTO_IP, bsd.IP_DROP_MEMBERSHIP, &request, @sizeOf(bsd.ip_mreq)));
    try testing.expectEqual(@as(i32, -1), sb.SetSockOpt(one, bsd.IPPROTO_IP, bsd.IP_DROP_MEMBERSHIP, &request, @sizeOf(bsd.ip_mreq)));
    try testing.expect(_igmp.isOurs(rig.interface, mdns));
    _ = sb.CloseSocket(two);
    try testing.expect(!_igmp.isOurs(rig.interface, mdns));
    _ = sb.CloseSocket(one);
    _ = sb.CloseSocket(outside);
    rig.pass(3_000_000);
    try rig.deinit();
}
