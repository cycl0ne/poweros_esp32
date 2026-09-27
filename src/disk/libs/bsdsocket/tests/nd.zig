// SPDX-License-Identifier: MIT
//! Host tests of Neighbor Discovery and MLD, on an Ethernet link the test
//! watches: every frame the stack sends is recorded with the station it
//! went to, and what the network says - solicitations, advertisements,
//! queries - is written by the test. Time is the test's to say.

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
const _icmp6 = @import("../icmp6/_icmp6.zig");
const _inet = @import("../inet/_inet.zig");
const _nd = @import("../nd/_nd.zig");
const mld = @import("../nd/mld.zig");
const _timer = @import("../timer/_timer.zig");
const Address = @import("../ip6/address.zig").Address;
const parse = @import("../ip6/address.zig").parse;
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;

const testing = std.testing;

const Sent = struct {
    to: [6]u8,
    bytes: [256]u8,
    length: usize,

    fn source(entry: *const Sent) Address {
        return .{ .bytes = entry.bytes[8..24].* };
    }

    fn destination(entry: *const Sent) Address {
        return .{ .bytes = entry.bytes[24..40].* };
    }

    /// The ICMPv6 message, behind the base header and a hop-by-hop
    /// header if there is one.
    fn message(entry: *const Sent) []const u8 {
        const at: usize = if (entry.bytes[6] == _ip6.hop_by_hop) 48 else 40;
        return entry.bytes[at..entry.length];
    }

    fn kind(entry: *const Sent) u8 {
        return entry.message()[0];
    }

    fn checksumRight(entry: *const Sent) bool {
        const body = entry.message();
        return _ip.finish(_ip.sum(_inet.pseudoSum(entry.source(), entry.destination(), _ip6.protocol_icmp6, @intCast(body.len)), body)) == 0;
    }
};

var sent: [32]Sent = undefined;
var sent_count: usize = 0;

fn capture(stack: *StackBase, _: *Interface, frame: *Frame, to: *const [6]u8, packet_type: u16) i32 {
    const bytes = frame.bytes();
    if (packet_type == _ip6.ethertype and sent_count < sent.len) {
        sent[sent_count] = .{ .to = to.*, .bytes = undefined, .length = @min(bytes.len, 256) };
        @memcpy(sent[sent_count].bytes[0..sent[sent_count].length], bytes[0..sent[sent_count].length]);
        sent_count += 1;
    }
    stack.frames.give(stack.sys_base, frame);
    return 0;
}

const own_hardware = [6]u8{ 0x02, 0, 0, 0, 0, 1 };
const peer_hardware = [6]u8{ 0x02, 0, 0, 0, 0, 2 };

fn address(comptime text: []const u8) Address {
    return comptime parse(text).?;
}

const own = address("fe80::ff:fe00:1");
const peer = address("fe80::2");

const Rig = struct {
    kub: *utility_library.UtilityBase,
    stack_lib: *exec.Library,
    sb: *SocketBase,
    stack: *StackBase,
    interface: *Interface,

    /// The stack with an interface on the watched link, IPv6 started but
    /// its link-local address not checked yet.
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
        sent_count = 0;
        _ip6.start(stack, interface);
        return .{ .kub = kub, .stack_lib = stack_lib, .sb = sb, .stack = stack, .interface = interface };
    }

    /// The link-local address checked, and what that sent forgotten.
    fn ready(rig: *Rig) void {
        rig.pass(3_000_000);
        // No router answers here: it is not asked for again.
        _timer.cancel(rig.stack, &rig.interface.ip6.routers.timer);
        sent_count = 0;
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

    /// An ICMPv6 message from the network with `hop_limit`, its checksum
    /// made.
    fn arrive(rig: *Rig, source: Address, destination: Address, hop_limit: u8, body: []const u8) void {
        const frame = rig.stack.frames.take(rig.stack.sys_base).?;
        const packet = frame.buffer[frame.start..][0 .. _ip6.header_bytes + body.len];
        frame.length = @intCast(packet.len);
        _ip.put32(packet, 0, 0x6000_0000);
        _ip.put16(packet, 4, @intCast(body.len));
        packet[6] = _ip6.protocol_icmp6;
        packet[7] = hop_limit;
        packet[8..24].* = source.bytes;
        packet[24..40].* = destination.bytes;
        const message = packet[_ip6.header_bytes..];
        @memcpy(message, body);
        _ip.put16(message, 2, 0);
        _ip.put16(message, 2, _ip.finish(_ip.sum(_inet.pseudoSum(source, destination, _ip6.protocol_icmp6, @intCast(message.len)), message)));
        _netif.receive(rig.stack, rig.interface, frame, &peer_hardware, &own_hardware, _ip6.ethertype, rig.stack.fixed_time);
    }

    /// A solicitation or advertisement of `kind` for `target`, with a
    /// link-layer option of `option` for `hardware` when it is given.
    fn nd(rig: *Rig, source: Address, destination: Address, kind: u8, flags: u8, target: Address, option: u8, hardware: ?[6]u8) void {
        var body: [32]u8 = @splat(0);
        body[0] = kind;
        body[4] = flags;
        body[8..24].* = target.bytes;
        var length: usize = 24;
        if (hardware) |station| {
            body[24] = option;
            body[25] = 1;
            body[26..32].* = station;
            length = 32;
        }
        rig.arrive(source, destination, 255, body[0..length]);
    }

    /// An echo request from the peer to us, which the stack answers.
    fn ping(rig: *Rig) void {
        const body = [_]u8{ _icmp6.echo_request, 0, 0, 0, 0, 1, 0, 1 };
        rig.arrive(peer, own, 64, &body);
    }
};

fn find(kind: u8) ?*const Sent {
    for (sent[0..sent_count]) |*entry| {
        if (entry.bytes[6] != _ip6.hop_by_hop and entry.kind() == kind) return entry;
    }
    return null;
}

fn count(kind: u8) usize {
    var found: usize = 0;
    for (sent[0..sent_count]) |*entry| {
        if (entry.kind() == kind) found += 1;
    }
    return found;
}

test "the link-local address is checked, then preferred; its group is reported" {
    var rig = try Rig.init();
    const entry = _ip6.addressOf(rig.interface, own).?;
    try testing.expectEqual(_ip6.AddressState.tentative, entry.state);
    try testing.expect(_ip6.linkLocal(rig.interface) == null);
    rig.pass(1_100_000);
    // The check: from ::, to the solicited-node group, with a nonce and
    // no Ethernet address.
    const check = find(_nd.neighbor_solicitation).?;
    try testing.expect(check.checksumRight());
    try testing.expect(check.source().isUnspecified());
    try testing.expect(check.destination().eql(own.solicitedNode()));
    try testing.expectEqual([6]u8{ 0x33, 0x33, 0xff, 0, 0, 1 }, check.to);
    try testing.expectEqual(@as(u8, 255), check.bytes[7]);
    try testing.expectEqual(@as(usize, 40 + 32), check.length);
    try testing.expectEqual(_nd.option_nonce, check.bytes[64]);
    rig.pass(1_000_000);
    try testing.expectEqual(_ip6.AddressState.preferred, entry.state);
    try testing.expect(_ip6.linkLocal(rig.interface).?.eql(own));
    // Two reports of the group, as MLDv2 has them.
    try testing.expectEqual(@as(usize, 2), count(mld.report));
    for (sent[0..sent_count]) |*report| {
        if (report.kind() != mld.report) continue;
        try testing.expect(report.checksumRight());
        try testing.expect(report.destination().eql(mld.all_routers));
        try testing.expectEqual(@as(u8, 1), report.bytes[7]);
        try testing.expectEqual(@as(u8, 5), report.bytes[42]); // router alert
        const body = report.message();
        try testing.expectEqual(@as(u16, 1), _ip.get16(body, 6));
        try testing.expectEqual(mld.to_exclude, body[8]);
        try testing.expectEqualSlices(u8, &own.solicitedNode().bytes, body[12..28]);
    }
    try rig.deinit();
}

test "an advertisement for a tentative address makes it a duplicate" {
    var rig = try Rig.init();
    rig.nd(peer, Address.all_nodes, _nd.neighbor_advertisement, _nd.flag_override, own, _nd.option_target, peer_hardware);
    try testing.expectEqual(_ip6.AddressState.duplicate, _ip6.addressOf(rig.interface, own).?.state);
    try testing.expectEqual(@as(u32, 1), rig.stack.counts.nd_duplicates);
    rig.pass(3_000_000);
    try testing.expect(_ip6.linkLocal(rig.interface) == null);
    try testing.expect(find(_nd.neighbor_solicitation) == null);
    try rig.deinit();
}

test "our own check coming back is not a duplicate; another station's is" {
    var rig = try Rig.init();
    rig.pass(1_100_000);
    const check = find(_nd.neighbor_solicitation).?;
    // The same solicitation, nonce and all, echoed by the link.
    rig.arrive(Address.any, own.solicitedNode(), 255, check.message());
    try testing.expectEqual(_ip6.AddressState.tentative, _ip6.addressOf(rig.interface, own).?.state);
    // Another station checking the same address, with its own nonce.
    var body: [32]u8 = @splat(0);
    @memcpy(body[0..32], check.message()[0..32]);
    body[26] ^= 0xff;
    rig.arrive(Address.any, own.solicitedNode(), 255, &body);
    try testing.expectEqual(_ip6.AddressState.duplicate, _ip6.addressOf(rig.interface, own).?.state);
    try rig.deinit();
}

test "a neighbor is solicited, the packet waits, and goes to the answer" {
    var rig = try Rig.init();
    rig.ready();
    rig.ping();
    // The reply waits; a solicitation for the peer went to its group.
    try testing.expectEqual(@as(usize, 1), sent_count);
    try testing.expectEqual(_nd.neighbor_solicitation, sent[0].kind());
    try testing.expect(sent[0].destination().eql(peer.solicitedNode()));
    try testing.expect(sent[0].source().eql(own));
    try testing.expectEqual(_nd.option_source, sent[0].bytes[64]);
    try testing.expectEqualSlices(u8, &own_hardware, sent[0].bytes[66..72]);
    try testing.expectEqual(_nd.State.incomplete, _nd.find(rig.stack, rig.interface, peer).?.state);

    rig.nd(peer, own, _nd.neighbor_advertisement, _nd.flag_solicited | _nd.flag_override, peer, _nd.option_target, peer_hardware);
    try testing.expectEqual(@as(usize, 2), sent_count);
    try testing.expectEqual(_icmp6.echo_reply, sent[1].kind());
    try testing.expectEqual(peer_hardware, sent[1].to);
    const entry = _nd.find(rig.stack, rig.interface, peer).?;
    try testing.expectEqual(_nd.State.reachable, entry.state);

    // Reachable at most 45 seconds, then stale; used, it is delayed, then
    // probed straight at the address it had.
    rig.pass(46_000_000);
    try testing.expectEqual(_nd.State.stale, entry.state);
    rig.ping();
    try testing.expectEqual(_nd.State.delay, entry.state);
    try testing.expectEqual(@as(usize, 3), sent_count);
    rig.pass(_nd.delay_us);
    try testing.expectEqual(_nd.State.probe, entry.state);
    try testing.expectEqual(_nd.neighbor_solicitation, sent[3].kind());
    try testing.expectEqual(peer_hardware, sent[3].to);
    try testing.expect(sent[3].destination().eql(peer));
    // Unanswered three times: gone.
    rig.pass(3_100_000);
    try testing.expectEqual(@as(usize, 3), count(_nd.neighbor_solicitation) - 1);
    try testing.expect(_nd.find(rig.stack, rig.interface, peer) == null);
    try rig.deinit();
}

test "an unanswered neighbor is asked three times, then its packets go" {
    var rig = try Rig.init();
    rig.ready();
    rig.ping();
    rig.ping();
    rig.pass(3_100_000);
    try testing.expectEqual(@as(usize, 3), count(_nd.neighbor_solicitation));
    try testing.expectEqual(@as(usize, 0), count(_icmp6.echo_reply));
    try testing.expectEqual(@as(u32, 2), rig.stack.counts.nd_dropped);
    try testing.expect(_nd.find(rig.stack, rig.interface, peer) == null);
    try rig.deinit();
}

test "a solicitation for our address is answered, and the asker learned" {
    var rig = try Rig.init();
    rig.ready();
    rig.nd(peer, own.solicitedNode(), _nd.neighbor_solicitation, 0, own, _nd.option_source, peer_hardware);
    try testing.expectEqual(@as(usize, 1), sent_count);
    const answer = &sent[0];
    try testing.expectEqual(_nd.neighbor_advertisement, answer.kind());
    try testing.expect(answer.checksumRight());
    try testing.expectEqual(peer_hardware, answer.to);
    try testing.expect(answer.source().eql(own));
    try testing.expect(answer.destination().eql(peer));
    try testing.expectEqual(_nd.flag_solicited | _nd.flag_override, answer.bytes[44]);
    try testing.expectEqual(_nd.option_target, answer.bytes[64]);
    try testing.expectEqualSlices(u8, &own_hardware, answer.bytes[66..72]);
    // Learned stale, and made delay by the answer sent to it.
    try testing.expectEqual(_nd.State.delay, _nd.find(rig.stack, rig.interface, peer).?.state);

    // From ::, the answer goes to all nodes.
    rig.nd(Address.any, own.solicitedNode(), _nd.neighbor_solicitation, 0, own, 0, null);
    try testing.expectEqual(@as(usize, 2), sent_count);
    try testing.expect(sent[1].destination().eql(Address.all_nodes));
    try testing.expectEqual(_nd.flag_override, sent[1].bytes[44]);
    try rig.deinit();
}

test "messages that fail the checks are not taken" {
    var rig = try Rig.init();
    rig.ready();
    var body: [32]u8 = @splat(0);
    body[0] = _nd.neighbor_solicitation;
    body[8..24].* = own.bytes;
    // Forwarded by a router.
    rig.arrive(peer, own.solicitedNode(), 64, body[0..24]);
    // An option of length 0.
    body[24] = _nd.option_source;
    rig.arrive(peer, own.solicitedNode(), 255, &body);
    // From :: with an Ethernet address.
    body[25] = 1;
    rig.arrive(Address.any, own.solicitedNode(), 255, &body);
    // A solicited advertisement to a group.
    rig.nd(peer, Address.all_nodes, _nd.neighbor_advertisement, _nd.flag_solicited, peer, _nd.option_target, peer_hardware);
    try testing.expectEqual(@as(usize, 0), sent_count);
    try testing.expectEqual(@as(u32, 4), rig.stack.counts.nd_bad);
    try rig.deinit();
}

test "a query is answered with the groups the interface is in" {
    var rig = try Rig.init();
    rig.ready();
    var body: [28]u8 = @splat(0);
    body[0] = mld.query;
    _ip.put16(&body, 4, 1000);
    rig.arrive(address("fe80::1"), Address.all_nodes, 1, &body);
    try testing.expectEqual(@as(usize, 0), sent_count);
    rig.pass(1_100_000);
    try testing.expectEqual(@as(usize, 1), count(mld.report));
    const report = sent[0].message();
    try testing.expectEqual(mld.mode_is_exclude, report[8]);
    try testing.expectEqualSlices(u8, &own.solicitedNode().bytes, report[12..28]);
    // A query from a router beyond the link is not taken.
    rig.arrive(address("2001:db8::1"), Address.all_nodes, 1, &body);
    rig.pass(1_100_000);
    try testing.expectEqual(@as(usize, 1), count(mld.report));
    try rig.deinit();
}

test "a removed address leaves its group, and says so" {
    var rig = try Rig.init();
    rig.ready();
    const extra = address("2001:db8::1:2:3");
    const entry = _ip6.addAddress(rig.stack, rig.interface, extra, 64, .preferred).?;
    rig.pass(3_000_000);
    sent_count = 0;
    _ip6.removeAddress(rig.stack, entry);
    rig.pass(3_000_000);
    try testing.expectEqual(@as(usize, 2), count(mld.report));
    const report = sent[0].message();
    try testing.expectEqual(@as(u16, 2), _ip.get16(report, 6));
    try testing.expectEqual(mld.to_include, report[28]);
    try testing.expectEqualSlices(u8, &extra.solicitedNode().bytes, report[32..48]);
    try rig.deinit();
}

// --- routers and SLAAC ----------------------------------------------------------------

const router = @import("../nd/router.zig");
const _route6 = @import("../route6/_route6.zig");
const gateway = address("fe80::1");
const global = address("2001:db8:1::ff:fe00:1");

/// A router advertisement from `gateway`: `lifetime_s` as a default
/// router, and a prefix, MTU and name-server option.
fn advertise(rig: *Rig, lifetime_s: u16, valid_s: u32, preferred_s: u32) void {
    var body: [16 + 8 + 32 + 8 + 24]u8 = @splat(0);
    body[0] = _nd.router_advertisement;
    body[4] = 64;
    body[5] = router.flag_other;
    _ip.put16(&body, 6, lifetime_s);
    var at: usize = 16;
    body[at..][0..8].* = .{ _nd.option_source, 1, 0x02, 0, 0, 0, 0, 0x99 };
    at += 8;
    body[at] = router.option_prefix;
    body[at + 1] = 4;
    body[at + 2] = 64;
    body[at + 3] = router.prefix_on_link | router.prefix_autonomous;
    _ip.put32(&body, at + 4, valid_s);
    _ip.put32(&body, at + 8, preferred_s);
    body[at + 16 ..][0..16].* = address("2001:db8:1::").bytes;
    at += 32;
    body[at] = router.option_mtu;
    body[at + 1] = 1;
    _ip.put32(&body, at + 4, 1400);
    at += 8;
    body[at] = router.option_rdnss;
    body[at + 1] = 3;
    _ip.put32(&body, at + 4, 600);
    body[at + 8 ..][0..16].* = address("2001:db8:1::53").bytes;
    rig.arrive(gateway, Address.all_nodes, 255, &body);
}

test "routers are solicited three times, four seconds apart, until one advertises" {
    var rig = try Rig.init();
    rig.pass(3_000_000);
    try testing.expectEqual(@as(usize, 1), count(_nd.router_solicitation));
    const solicitation = find(_nd.router_solicitation).?;
    try testing.expect(solicitation.checksumRight());
    try testing.expect(solicitation.destination().eql(Address.all_routers));
    try testing.expect(solicitation.source().eql(own));
    try testing.expectEqual(_nd.option_source, solicitation.bytes[48]);
    rig.pass(4_000_000);
    try testing.expectEqual(@as(usize, 2), count(_nd.router_solicitation));
    advertise(&rig, 1800, 86400, 14400);
    rig.pass(10_000_000);
    try testing.expectEqual(@as(usize, 2), count(_nd.router_solicitation));
    try rig.deinit();
}

test "an advertisement gives a default route, an on-link prefix, an address, an MTU and a name server" {
    var rig = try Rig.init();
    rig.ready();
    advertise(&rig, 1800, 86400, 14400);
    const made = _ip6.addressOf(rig.interface, global).?;
    try testing.expectEqual(_ip6.AddressState.tentative, made.state);
    try testing.expectEqual(@as(u8, 1), made.autoconf);
    rig.pass(2_100_000);
    try testing.expectEqual(_ip6.AddressState.preferred, made.state);
    try testing.expectEqual(@as(u8, router.flag_other), rig.interface.ip6.routers.flags);
    // The router learned, as a router.
    const neighbor = _nd.find(rig.stack, rig.interface, gateway).?;
    try testing.expectEqual(@as(u8, 1), neighbor.router);
    try testing.expectEqual([6]u8{ 0x02, 0, 0, 0, 0, 0x99 }, neighbor.hardware);

    const far = address("2001:db8:2::1");
    const path = _inet.route(rig.stack, far, null).?;
    try testing.expect(path.next_hop.eql(gateway));
    try testing.expectEqual(@as(u32, 1400), path.mtu);
    try testing.expect(_inet.sourceFor(path, far).?.eql(global));
    const near = address("2001:db8:1::5");
    try testing.expect(_inet.route(rig.stack, near, null).?.next_hop.eql(near));

    var servers: [3]Address = undefined;
    try testing.expectEqual(@as(usize, 1), router.nameServers(rig.interface, rig.stack.fixed_time, &servers));
    try testing.expect(servers[0].eql(address("2001:db8:1::53")));

    // Lifetime 0: the router is no default any more.
    advertise(&rig, 0, 86400, 14400);
    try testing.expect(_inet.route(rig.stack, far, null) == null);
    try testing.expect(_inet.route(rig.stack, near, null) != null);
    try rig.deinit();
}

test "an address is deprecated, then goes, as its lifetimes say" {
    var rig = try Rig.init();
    rig.ready();
    advertise(&rig, 1800, 20, 10);
    rig.pass(2_100_000);
    const made = _ip6.addressOf(rig.interface, global).?;
    try testing.expectEqual(_ip6.AddressState.preferred, made.state);
    rig.pass(8_000_000);
    try testing.expectEqual(_ip6.AddressState.deprecated, made.state);
    // Deprecated: not picked while another will do... none will here,
    // so it is still the source for a global destination.
    try testing.expect(_inet.sourceFor(_inet.route(rig.stack, address("2001:db8:2::1"), null).?, address("2001:db8:2::1")).?.eql(global));
    rig.pass(10_000_000);
    try testing.expect(_ip6.addressOf(rig.interface, global) == null);
    try rig.deinit();
}

test "a short valid lifetime cuts a long one only down to two hours" {
    var rig = try Rig.init();
    rig.ready();
    advertise(&rig, 1800, 0xFFFF_FFFF, 0xFFFF_FFFF);
    rig.pass(2_100_000);
    const made = _ip6.addressOf(rig.interface, global).?;
    try testing.expectEqual(@as(u64, 0), made.valid_until);
    advertise(&rig, 1800, 60, 30);
    try testing.expectEqual(rig.stack.fixed_time + @import("../nd/slaac.zig").two_hours_us, made.valid_until);
    try testing.expectEqual(rig.stack.fixed_time + 30_000_000, made.preferred_until);
    try rig.deinit();
}

test "an advertisement from beyond the link is not taken" {
    var rig = try Rig.init();
    rig.ready();
    var body: [16]u8 = @splat(0);
    body[0] = _nd.router_advertisement;
    _ip.put16(&body, 6, 1800);
    rig.arrive(address("2001:db8::1"), Address.all_nodes, 255, &body);
    try testing.expectEqual(@as(u32, 1), rig.stack.counts.nd_bad);
    try testing.expect(_inet.route(rig.stack, address("2001:db8:2::1"), null) == null);
    try rig.deinit();
}

test "a redirect from the router sends a destination elsewhere" {
    var rig = try Rig.init();
    rig.ready();
    advertise(&rig, 1800, 86400, 14400);
    rig.pass(2_100_000);
    const far = address("2001:db8:2::9");
    const better = address("fe80::77");
    var body: [48]u8 = @splat(0);
    body[0] = _nd.redirect;
    body[8..24].* = better.bytes;
    body[24..40].* = far.bytes;
    body[40..48].* = .{ _nd.option_target, 1, 0x02, 0, 0, 0, 0, 0x77 };
    // Not from the router that is the next hop: ignored.
    rig.arrive(better, own, 255, &body);
    try testing.expect(_inet.route(rig.stack, far, null).?.next_hop.eql(gateway));
    rig.arrive(gateway, own, 255, &body);
    try testing.expect(_inet.route(rig.stack, far, null).?.next_hop.eql(better));
    try testing.expectEqual([6]u8{ 0x02, 0, 0, 0, 0, 0x77 }, _nd.find(rig.stack, rig.interface, better).?.hardware);
    // Other destinations still go through the router.
    try testing.expect(_inet.route(rig.stack, address("2001:db8:2::8"), null).?.next_hop.eql(gateway));
    rig.pass(router.redirect_life_us);
    try testing.expect(_inet.route(rig.stack, far, null).?.next_hop.eql(gateway));
    try rig.deinit();
}
