// SPDX-License-Identifier: MIT
//! Host tests of the DHCPv6 client, with the test as the router and the
//! server: what the client sends is caught at the interface's link, and
//! the advertisements and the server's answers are written by the test
//! and handed to the stack. Time is the test's.

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
const _ip6 = @import("../ip6/_ip6.zig");
const _inet = @import("../inet/_inet.zig");
const _nd = @import("../nd/_nd.zig");
const router = @import("../nd/router.zig");
const _dhcp6 = @import("../dhcp6/_dhcp6.zig");
const _timer = @import("../timer/_timer.zig");
const Address = @import("../ip6/address.zig").Address;
const parse = @import("../ip6/address.zig").parse;
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;

const testing = std.testing;

fn address(comptime text: []const u8) Address {
    return comptime parse(text).?;
}

const own_hardware = [6]u8{ 0x02, 0, 0, 0, 0, 1 };
const peer_hardware = [6]u8{ 0x02, 0, 0, 0, 0, 2 };
const own = address("fe80::ff:fe00:1");
const gateway = address("fe80::1");
const server = address("fe80::53");
const server_duid = [_]u8{ 0, 3, 0, 1, 0x02, 0, 0, 0, 0, 0x53 };
/// Our DUID-LL, from our Ethernet address.
const own_duid = [_]u8{ 0, 3, 0, 1 } ++ own_hardware;
const leased = address("2001:db8:1::100");
const name_server = address("2001:db8:1::53");

// --- the link ----------------------------------------------------------------------

/// A DHCPv6 message the client sent: its type, transaction, and options.
const Sent = struct {
    bytes: [256]u8,
    length: usize,
    hop_limit: u8,
    source: Address,
    destination: Address,

    fn message(entry: *const Sent) []const u8 {
        return entry.bytes[0..entry.length];
    }

    fn kind(entry: *const Sent) u8 {
        return entry.bytes[0];
    }

    fn xid(entry: *const Sent) u32 {
        return @as(u32, entry.bytes[1]) << 16 | @as(u32, entry.bytes[2]) << 8 | entry.bytes[3];
    }

    /// The data of the first option of `code`, if there is one.
    fn option(entry: *const Sent, code: u16) ?[]const u8 {
        return optionIn(entry.message()[4..], code);
    }

    /// Whether its IA_NA holds `wanted`.
    fn holds(entry: *const Sent, wanted: Address) bool {
        const ia = entry.option(_dhcp6.option_ia_na) orelse return false;
        const held = optionIn(ia[12..], _dhcp6.option_ia_address) orelse return false;
        return std.mem.eql(u8, held[0..16], &wanted.bytes);
    }
};

fn optionIn(options: []const u8, code: u16) ?[]const u8 {
    var at: usize = 0;
    while (at + 4 <= options.len) {
        const length = _ip.get16(options, at + 2);
        if (_ip.get16(options, at) == code) return options[at + 4 ..][0..length];
        at += 4 + length;
    }
    return null;
}

var sent: [32]Sent = undefined;
var sent_count: usize = 0;
/// IPv6 frames that were no DHCPv6: neighbor solicitations, reports.
var other_count: usize = 0;

fn capture(stack: *StackBase, _: *Interface, frame: *Frame, _: *const [6]u8, packet_type: u16) i32 {
    const bytes = frame.bytes();
    defer stack.frames.give(stack.sys_base, frame);
    if (packet_type != _ip6.ethertype) return 0;
    if (bytes.len < 48 or bytes[6] != 17 or _ip.get16(bytes, 42) != _dhcp6.server_port) {
        other_count += 1;
        return 0;
    }
    const udp = bytes[40..];
    // The UDP checksum is right.
    const source: Address = .{ .bytes = bytes[8..24].* };
    const destination: Address = .{ .bytes = bytes[24..40].* };
    if (_ip.finish(_ip.sum(_inet.pseudoSum(source, destination, 17, @intCast(udp.len)), udp)) != 0) return 0;
    if (sent_count == sent.len) return 0;
    const length = @min(udp.len - 8, 256);
    sent[sent_count] = .{ .bytes = undefined, .length = length, .hop_limit = bytes[7], .source = source, .destination = destination };
    @memcpy(sent[sent_count].bytes[0..length], udp[8..][0..length]);
    sent_count += 1;
    return 0;
}

fn last() ?*const Sent {
    return if (sent_count == 0) null else &sent[sent_count - 1];
}

fn count(kind: u8) usize {
    var found: usize = 0;
    for (sent[0..sent_count]) |*entry| {
        if (entry.kind() == kind) found += 1;
    }
    return found;
}

fn find(kind: u8) ?*const Sent {
    var found: ?*const Sent = null;
    for (sent[0..sent_count]) |*entry| {
        if (entry.kind() == kind) found = entry;
    }
    return found;
}

const Rig = struct {
    kub: *utility_library.UtilityBase,
    stack_lib: *exec.Library,
    sb: *SocketBase,
    stack: *StackBase,
    interface: *Interface,

    /// The stack with an interface on the watched link, its link-local
    /// address checked.
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
        interface.* = .{ .mtu = 1500, .used = 1, .up = 1, .hardware = own_hardware, .transmit = &capture };
        @memcpy(interface.name[0..4], "test");
        interface.ip6.identifier = bsd.IFID_EUI64;
        _ip6.start(stack, interface);
        var rig: Rig = .{ .kub = kub, .stack_lib = stack_lib, .sb = sb, .stack = stack, .interface = interface };
        rig.pass(3_000_000);
        _timer.cancel(stack, &interface.ip6.routers.timer);
        sent_count = 0;
        other_count = 0;
        return rig;
    }

    fn deinit(rig: *Rig) !void {
        const sys = kexec.SysBase.iface();
        _ip6.stop(rig.stack, rig.interface);
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

    /// An IPv6 packet from the network carrying `body` of `protocol`,
    /// its checksum made at `checksum_at` in it.
    fn arrive(rig: *Rig, source: Address, destination: Address, protocol: u8, hop_limit: u8, body: []const u8, checksum_at: usize) void {
        const frame = rig.stack.frames.take(rig.stack.sys_base).?;
        const packet = frame.buffer[frame.start..][0 .. _ip6.header_bytes + body.len];
        frame.length = @intCast(packet.len);
        _ip.put32(packet, 0, 0x6000_0000);
        _ip.put16(packet, 4, @intCast(body.len));
        packet[6] = protocol;
        packet[7] = hop_limit;
        packet[8..24].* = source.bytes;
        packet[24..40].* = destination.bytes;
        const payload = packet[_ip6.header_bytes..];
        @memcpy(payload, body);
        _ip.put16(payload, checksum_at, 0);
        _ip.put16(payload, checksum_at, _ip.finish(_ip.sum(_inet.pseudoSum(source, destination, protocol, @intCast(payload.len)), payload)));
        _netif.receive(rig.stack, rig.interface, frame, &peer_hardware, &own_hardware, _ip6.ethertype, rig.stack.fixed_time);
    }

    /// A router advertisement with `flags` (M, O) and the prefix
    /// 2001:db8:1::/64 on the link, with no addresses from it.
    fn advertise(rig: *Rig, flags: u8) void {
        var body: [16 + 8 + 32]u8 = @splat(0);
        body[0] = _nd.router_advertisement;
        body[4] = 64;
        body[5] = flags;
        _ip.put16(&body, 6, 1800);
        body[16..24].* = .{ _nd.option_source, 1, 0x02, 0, 0, 0, 0, 0x99 };
        body[24] = router.option_prefix;
        body[25] = 4;
        body[26] = 64;
        body[27] = router.prefix_on_link;
        _ip.put32(&body, 28, 86400);
        _ip.put32(&body, 32, 14400);
        body[40..56].* = address("2001:db8:1::").bytes;
        rig.arrive(gateway, Address.all_nodes, 58, 255, &body, 2);
    }

    /// A server's message of `kind` for transaction `xid`, its options
    /// `options` behind the client's id, sent to our link-local address.
    fn answer(rig: *Rig, kind: u8, xid: u32, options: []const u8) void {
        var body: [512]u8 = undefined;
        var at: usize = 8;
        body[at] = kind;
        body[at + 1] = @truncate(xid >> 16);
        body[at + 2] = @truncate(xid >> 8);
        body[at + 3] = @truncate(xid);
        at += 4;
        at = put(&body, at, _dhcp6.option_client_id, &own_duid);
        @memcpy(body[at..][0..options.len], options);
        at += options.len;
        _ip.put16(&body, 0, _dhcp6.server_port);
        _ip.put16(&body, 2, _dhcp6.client_port);
        _ip.put16(&body, 4, @intCast(at));
        rig.arrive(server, own, 17, 64, body[0..at], 6);
    }
};

fn put(into: []u8, at: usize, code: u16, data: []const u8) usize {
    _ip.put16(into, at, code);
    _ip.put16(into, at + 2, @intCast(data.len));
    @memcpy(into[at + 4 ..][0..data.len], data);
    return at + 4 + data.len;
}

/// Options a server sends: its id, an IA_NA for the interface with
/// `offered` for `preferred_s` and `valid_s`, T1 and T2, and with
/// `settings` a name server and a domain list.
fn serverOptions(into: []u8, rig: *Rig, offered: Address, t1_s: u32, t2_s: u32, preferred_s: u32, valid_s: u32, preference: ?u8, settings: bool) usize {
    var at = put(into, 0, _dhcp6.option_server_id, &server_duid);
    var ia: [12 + 4 + 24]u8 = undefined;
    _ip.put32(&ia, 0, _netif.index(rig.stack, rig.interface));
    _ip.put32(&ia, 4, t1_s);
    _ip.put32(&ia, 8, t2_s);
    var entry: [24]u8 = undefined;
    entry[0..16].* = offered.bytes;
    _ip.put32(&entry, 16, preferred_s);
    _ip.put32(&entry, 20, valid_s);
    _ = put(&ia, 12, _dhcp6.option_ia_address, &entry);
    at = put(into, at, _dhcp6.option_ia_na, &ia);
    if (preference) |value| at = put(into, at, _dhcp6.option_preference, &.{value});
    if (settings) {
        at = put(into, at, _dhcp6.option_dns_servers, &name_server.bytes);
        at = put(into, at, _dhcp6.option_domain_list, "\x04corp\x07example\x00");
    }
    return at;
}

// --- the tests ------------------------------------------------------------------------

test "M flag: solicit, advertise, request, reply; the address checked, the name server and domain kept" {
    var rig = try Rig.init();
    rig.advertise(router.flag_managed | router.flag_other);
    rig.pass(1_100_000);
    const solicit = find(_dhcp6.solicit).?;
    try testing.expect(solicit.destination.eql(_dhcp6.all_servers));
    try testing.expect(solicit.source.eql(own));
    try testing.expectEqual(@as(u8, 1), solicit.hop_limit);
    try testing.expectEqualSlices(u8, &own_duid, solicit.option(_dhcp6.option_client_id).?);
    try testing.expectEqual(_netif.index(rig.stack, rig.interface), _ip.get32(solicit.option(_dhcp6.option_ia_na).?, 0));
    try testing.expect(solicit.option(_dhcp6.option_elapsed_time) != null);
    try testing.expect(solicit.option(_dhcp6.option_request) != null);
    try testing.expect(solicit.option(_dhcp6.option_server_id) == null);

    // An ADVERTISE in the first retransmission time is held until it is
    // over; then REQUEST to its server, for its address.
    var options: [256]u8 = undefined;
    var length = serverOptions(&options, &rig, leased, 0, 0, 0, 0, null, false);
    rig.answer(_dhcp6.advertise, solicit.xid(), options[0..length]);
    try testing.expectEqual(@as(usize, 0), count(_dhcp6.request));
    rig.pass(1_200_000);
    const asked = find(_dhcp6.request).?;
    try testing.expectEqualSlices(u8, &server_duid, asked.option(_dhcp6.option_server_id).?);
    try testing.expect(asked.holds(leased));
    try testing.expect(asked.xid() != solicit.xid());

    // The REPLY: the address, alone, checked before it is used.
    length = serverOptions(&options, &rig, leased, 100, 160, 200, 300, null, true);
    rig.answer(_dhcp6.reply, asked.xid(), options[0..length]);
    const entry = _ip6.addressOf(rig.interface, leased).?;
    try testing.expectEqual(_ip6.AddressState.tentative, entry.state);
    try testing.expectEqual(@as(u8, 128), entry.prefix_length);
    try testing.expectEqual(@as(u8, 1), entry.dhcp6);
    rig.pass(2_100_000);
    try testing.expectEqual(_ip6.AddressState.preferred, entry.state);
    var servers: [3]Address = undefined;
    try testing.expectEqual(@as(usize, 1), router.nameServers(rig.interface, rig.stack.fixed_time, &servers));
    try testing.expect(servers[0].eql(name_server));
    try testing.expectEqualStrings("corp.example", router.searchDomainOf(rig.interface, rig.stack.fixed_time).?);
    var infos: [_ip6.addresses_max]bsd.Address6Info = undefined;
    const listed = rig.sb.GetNetworkStatistics(bsd.NETSTATUS_ADDRESSES6, &infos, @sizeOf(@TypeOf(infos)));
    var marked: usize = 0;
    for (infos[0..@intCast(listed)]) |*info| marked += info.dhcp;
    try testing.expectEqual(@as(usize, 1), marked);

    // At T1, RENEW with the server; its REPLY sets the lifetimes again.
    sent_count = 0;
    rig.pass(98_000_000);
    const renewal = find(_dhcp6.renew).?;
    try testing.expectEqualSlices(u8, &server_duid, renewal.option(_dhcp6.option_server_id).?);
    try testing.expect(renewal.holds(leased));
    length = serverOptions(&options, &rig, leased, 100, 160, 200, 300, null, true);
    rig.answer(_dhcp6.reply, renewal.xid(), options[0..length]);
    try testing.expectEqual(rig.stack.fixed_time + 300_000_000, entry.valid_until);

    // No answer from here on: RENEW again, REBIND at T2 to any server,
    // and when the address ends it goes and SOLICIT starts over.
    sent_count = 0;
    rig.pass(161_000_000);
    try testing.expect(count(_dhcp6.renew) >= 2);
    const rebinding = find(_dhcp6.rebind).?;
    try testing.expect(rebinding.option(_dhcp6.option_server_id) == null);
    try testing.expect(rebinding.holds(leased));
    rig.pass(140_000_000);
    try testing.expect(_ip6.addressOf(rig.interface, leased) == null);
    rig.pass(1_100_000);
    try testing.expect(find(_dhcp6.solicit) != null);
    try rig.deinit();
}

test "preference 255 is asked at once; a duplicate address is declined, and it starts again" {
    var rig = try Rig.init();
    rig.advertise(router.flag_managed);
    rig.pass(1_100_000);
    const solicit = find(_dhcp6.solicit).?;
    var options: [256]u8 = undefined;
    var length = serverOptions(&options, &rig, leased, 0, 0, 0, 0, 255, false);
    rig.answer(_dhcp6.advertise, solicit.xid(), options[0..length]);
    rig.pass(100_000);
    const asked = find(_dhcp6.request).?;
    length = serverOptions(&options, &rig, leased, 100, 160, 200, 300, null, false);
    rig.answer(_dhcp6.reply, asked.xid(), options[0..length]);
    try testing.expect(_ip6.addressOf(rig.interface, leased) != null);

    // Another station has it.
    sent_count = 0;
    var body: [32]u8 = @splat(0);
    body[0] = _nd.neighbor_advertisement;
    body[4] = _nd.flag_override;
    body[8..24].* = leased.bytes;
    body[24] = _nd.option_target;
    body[25] = 1;
    body[26..32].* = peer_hardware;
    rig.arrive(address("fe80::2"), Address.all_nodes, 58, 255, &body, 2);
    try testing.expect(_ip6.addressOf(rig.interface, leased) == null);
    const declined = find(_dhcp6.decline).?;
    try testing.expectEqualSlices(u8, &server_duid, declined.option(_dhcp6.option_server_id).?);
    try testing.expect(declined.holds(leased));
    rig.pass(1_100_000);
    try testing.expect(find(_dhcp6.solicit) != null);
    try rig.deinit();
}

test "O flag alone: name servers asked for, and asked again after the refresh time" {
    var rig = try Rig.init();
    rig.advertise(router.flag_other);
    rig.pass(1_100_000);
    try testing.expectEqual(@as(usize, 0), count(_dhcp6.solicit));
    const asked = find(_dhcp6.information_request).?;
    try testing.expect(asked.option(_dhcp6.option_ia_na) == null);
    try testing.expectEqual(@as(usize, 6), asked.option(_dhcp6.option_request).?.len);
    var options: [128]u8 = undefined;
    var length = put(&options, 0, _dhcp6.option_server_id, &server_duid);
    length = put(&options, length, _dhcp6.option_dns_servers, &name_server.bytes);
    var refresh: [4]u8 = undefined;
    _ip.put32(&refresh, 0, 700);
    length = put(&options, length, _dhcp6.option_refresh_time, &refresh);
    rig.answer(_dhcp6.reply, asked.xid(), options[0..length]);
    var servers: [3]Address = undefined;
    try testing.expectEqual(@as(usize, 1), router.nameServers(rig.interface, rig.stack.fixed_time, &servers));
    // Not asked again before its time; at it, again.
    sent_count = 0;
    rig.pass(699_000_000);
    try testing.expectEqual(@as(usize, 0), count(_dhcp6.information_request));
    rig.pass(2_100_000);
    try testing.expectEqual(@as(usize, 1), count(_dhcp6.information_request));
    // The servers stay while it is asked.
    try testing.expectEqual(@as(usize, 1), router.nameServers(rig.interface, rig.stack.fixed_time, &servers));
    // The M flag now: addresses after all.
    rig.advertise(router.flag_managed | router.flag_other);
    rig.pass(1_100_000);
    try testing.expect(find(_dhcp6.solicit) != null);
    try rig.deinit();
}

test "what is not for us is not taken; the lease is given back when the interface goes" {
    var rig = try Rig.init();
    rig.advertise(router.flag_managed);
    rig.pass(1_100_000);
    const solicit = find(_dhcp6.solicit).?;
    var options: [256]u8 = undefined;
    var length = serverOptions(&options, &rig, leased, 0, 0, 0, 0, 255, false);
    // Another transaction: nothing.
    rig.answer(_dhcp6.advertise, solicit.xid() ^ 1, options[0..length]);
    rig.pass(100_000);
    try testing.expectEqual(@as(usize, 0), count(_dhcp6.request));
    rig.answer(_dhcp6.advertise, solicit.xid(), options[0..length]);
    rig.pass(100_000);
    const asked = find(_dhcp6.request).?;
    length = serverOptions(&options, &rig, leased, 100, 160, 200, 300, null, false);
    rig.answer(_dhcp6.reply, asked.xid(), options[0..length]);
    rig.pass(2_100_000);
    // Gone: RELEASE, with the server and the address.
    sent_count = 0;
    _dhcp6.giveBack(rig.stack, rig.interface);
    const given = find(_dhcp6.release).?;
    try testing.expectEqualSlices(u8, &server_duid, given.option(_dhcp6.option_server_id).?);
    try testing.expect(given.holds(leased));
    try testing.expect(given.option(_dhcp6.option_request) == null);
    // Idle now: a server's message is left to the sockets.
    try testing.expect(!_dhcp6.input(rig.stack, rig.interface, &.{ _dhcp6.reply, 0, 0, 0 }));
    try rig.deinit();
}
