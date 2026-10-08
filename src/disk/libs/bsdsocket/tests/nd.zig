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

    /// Time moved on by `us` at once, each timer run at its deadline: for
    /// days, which `pass` would take too long over.
    fn leap(rig: *Rig, us: u64) void {
        const end = rig.stack.fixed_time + us;
        while (_timer.earliest(rig.stack)) |due| {
            if (due > end) break;
            rig.stack.fixed_time = @max(due, rig.stack.fixed_time);
            _timer.run(rig.stack, rig.stack.fixed_time);
        }
        rig.stack.fixed_time = end;
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

test "a DNSSL option names the domain a name without dots is looked for in" {
    var rig = try Rig.init();
    rig.ready();
    var body: [16 + 24]u8 = @splat(0);
    body[0] = _nd.router_advertisement;
    _ip.put16(&body, 6, 1800);
    body[16] = router.option_dnssl;
    body[17] = 3;
    _ip.put32(&body, 16 + 4, 600);
    const labels = [_]u8{ 4, 'h', 'o', 'm', 'e', 3, 'l', 'a', 'n', 0 };
    @memcpy(body[24..][0..labels.len], &labels);
    rig.arrive(gateway, Address.all_nodes, 255, &body);
    try testing.expectEqualStrings("home.lan", router.searchDomainOf(rig.interface, rig.stack.fixed_time).?);
    rig.pass(601_000_000);
    try testing.expect(router.searchDomainOf(rig.interface, rig.stack.fixed_time) == null);
    try rig.deinit();
}

test "an MLDv1 querier is answered in MLDv1, until it has gone quiet" {
    var rig = try Rig.init();
    rig.ready();
    var query: [24]u8 = @splat(0);
    query[0] = mld.query;
    _ip.put16(&query, 4, 1000);
    rig.arrive(address("fe80::1"), Address.all_nodes, 1, &query);
    rig.pass(1_100_000);
    // One Report per group, to the group itself.
    try testing.expectEqual(@as(usize, 1), count(mld.report_v1));
    try testing.expectEqual(@as(usize, 0), count(mld.report));
    const answer = &sent[0];
    try testing.expect(answer.checksumRight());
    try testing.expect(answer.destination().eql(own.solicitedNode()));
    try testing.expectEqualSlices(u8, &own.solicitedNode().bytes, answer.message()[8..24]);
    // A group left is told with a Done, to all routers.
    sent_count = 0;
    const extra = address("2001:db8::7:8:9");
    const entry = _ip6.addAddress(rig.stack, rig.interface, extra, 64, .preferred).?;
    rig.pass(3_000_000);
    sent_count = 0;
    _ip6.removeAddress(rig.stack, entry);
    rig.pass(3_000_000);
    try testing.expect(count(mld.done_v1) >= 1);
    for (sent[0..sent_count]) |*message| {
        if (message.kind() == mld.done_v1) try testing.expect(message.destination().eql(Address.all_routers));
    }
    // After the timeout, MLDv2 again.
    rig.pass(mld.v1_present_us);
    sent_count = 0;
    var query2: [28]u8 = @splat(0);
    query2[0] = mld.query;
    _ip.put16(&query2, 4, 1000);
    rig.arrive(address("fe80::1"), Address.all_nodes, 1, &query2);
    rig.pass(1_100_000);
    try testing.expectEqual(@as(usize, 1), count(mld.report));
    try rig.deinit();
}

// --- sockets in groups -----------------------------------------------------------

const mdns = address("ff02::fb");

fn groupSocket(rig: *Rig) !i32 {
    const sb = rig.sb;
    const socket = sb.Socket(bsd.PF_INET6, bsd.SOCK_DGRAM, 0);
    if (socket < 0) return error.NoSocket;
    _ = sb.IoctlSocket(socket, bsd.FIONBIO, @constCast(&@as(u32, 1)));
    const on: i32 = 1;
    _ = sb.SetSockOpt(socket, bsd.SOL_SOCKET, bsd.SO_REUSEADDR, &on, @sizeOf(i32));
    var here: bsd.sockaddr_in6 = .{ .sin6_port = bsd.htons(5353) };
    try testing.expectEqual(@as(i32, 0), sb.Bind(socket, here.anyConst(), @sizeOf(bsd.sockaddr_in6)));
    const request: bsd.ipv6_mreq = .{ .ipv6mr_multiaddr = .{ .s6_addr = mdns.bytes }, .ipv6mr_interface = _netif.index(rig.stack, rig.interface) };
    try testing.expectEqual(@as(i32, 0), sb.SetSockOpt(socket, bsd.IPPROTO_IPV6, bsd.IPV6_JOIN_GROUP, &request, @sizeOf(bsd.ipv6_mreq)));
    return socket;
}

/// A UDP datagram from the peer to the group.
fn toGroup(rig: *Rig, text: []const u8) void {
    var body: [64]u8 = undefined;
    const datagram = body[0 .. 8 + text.len];
    _ip.put16(datagram, 0, 5353);
    _ip.put16(datagram, 2, 5353);
    _ip.put16(datagram, 4, @intCast(datagram.len));
    _ip.put16(datagram, 6, 0);
    @memcpy(datagram[8..], text);
    _ip.put16(datagram, 6, _ip.finish(_ip.sum(_inet.pseudoSum(peer, mdns, @intCast(bsd.IPPROTO_UDP), @intCast(datagram.len)), datagram)));
    const frame = rig.stack.frames.take(rig.stack.sys_base).?;
    const packet = frame.buffer[frame.start..][0 .. _ip6.header_bytes + datagram.len];
    frame.length = @intCast(packet.len);
    _ip.put32(packet, 0, 0x6000_0000);
    _ip.put16(packet, 4, @intCast(datagram.len));
    packet[6] = @intCast(bsd.IPPROTO_UDP);
    packet[7] = 255;
    packet[8..24].* = peer.bytes;
    packet[24..40].* = mdns.bytes;
    @memcpy(packet[_ip6.header_bytes..], datagram);
    _netif.receive(rig.stack, rig.interface, frame, &peer_hardware, &[6]u8{ 0x33, 0x33, 0, 0, 0, 0xfb }, _ip6.ethertype, rig.stack.fixed_time);
}

test "sockets in a group: joined, reported, each given what comes, and left" {
    var rig = try Rig.init();
    rig.ready();
    const sb = rig.sb;
    const one = try groupSocket(&rig);
    const two = try groupSocket(&rig);
    // The group is reported, once for both.
    rig.pass(3_000_000);
    var reported = false;
    for (sent[0..sent_count]) |*entry| {
        if (entry.kind() != mld.report) continue;
        const body = entry.message();
        const records = _ip.get16(body, 6);
        var at: usize = 8;
        for (0..records) |_| {
            if (std.mem.eql(u8, body[at + 4 ..][0..16], &mdns.bytes)) reported = true;
            at += 20;
        }
    }
    try testing.expect(reported);

    // What comes to the group, both get.
    toGroup(&rig, "hello");
    var buffer: [64]u8 = undefined;
    try testing.expectEqual(@as(i32, 5), sb.Recv(one, &buffer, buffer.len, 0));
    try testing.expectEqual(@as(i32, 5), sb.Recv(two, &buffer, buffer.len, 0));

    // Sent to the group: out on the link to its Ethernet group with a hop
    // limit of 1, and a copy for this machine's members.
    sent_count = 0;
    var to: bsd.sockaddr_in6 = .{ .sin6_port = bsd.htons(5353), .sin6_addr = .{ .s6_addr = mdns.bytes }, .sin6_scope_id = _netif.index(rig.stack, rig.interface) };
    try testing.expectEqual(@as(i32, 3), sb.SendTo(one, "ask", 3, 0, to.anyConst(), @sizeOf(bsd.sockaddr_in6)));
    try testing.expectEqual(@as(usize, 1), sent_count);
    try testing.expectEqual([6]u8{ 0x33, 0x33, 0, 0, 0, 0xfb }, sent[0].to);
    try testing.expectEqual(@as(u8, 1), sent[0].bytes[7]);
    try testing.expectEqual(@as(i32, 3), sb.Recv(one, &buffer, buffer.len, 0));
    try testing.expectEqual(@as(i32, 3), sb.Recv(two, &buffer, buffer.len, 0));
    // Without the loop, no copy; with a hop limit set, that one.
    const off: i32 = 0;
    try testing.expectEqual(@as(i32, 0), sb.SetSockOpt(one, bsd.IPPROTO_IPV6, bsd.IPV6_MULTICAST_LOOP, &off, @sizeOf(i32)));
    const hops: i32 = 255;
    try testing.expectEqual(@as(i32, 0), sb.SetSockOpt(one, bsd.IPPROTO_IPV6, bsd.IPV6_MULTICAST_HOPS, &hops, @sizeOf(i32)));
    _ = sb.SendTo(one, "ask", 3, 0, to.anyConst(), @sizeOf(bsd.sockaddr_in6));
    try testing.expectEqual(@as(u8, 255), sent[1].bytes[7]);
    try testing.expectEqual(@as(i32, -1), sb.Recv(two, &buffer, buffer.len, 0));

    // One leaves: still in the group through the other. Both gone: left,
    // and said so.
    const request: bsd.ipv6_mreq = .{ .ipv6mr_multiaddr = .{ .s6_addr = mdns.bytes }, .ipv6mr_interface = _netif.index(rig.stack, rig.interface) };
    try testing.expectEqual(@as(i32, 0), sb.SetSockOpt(one, bsd.IPPROTO_IPV6, bsd.IPV6_LEAVE_GROUP, &request, @sizeOf(bsd.ipv6_mreq)));
    try testing.expectEqual(@as(i32, -1), sb.SetSockOpt(one, bsd.IPPROTO_IPV6, bsd.IPV6_LEAVE_GROUP, &request, @sizeOf(bsd.ipv6_mreq)));
    try testing.expect(_ip6.isOurs(rig.stack, rig.interface, mdns));
    sent_count = 0;
    _ = sb.CloseSocket(two);
    try testing.expect(!_ip6.isOurs(rig.stack, rig.interface, mdns));
    rig.pass(3_000_000);
    var left = false;
    for (sent[0..sent_count]) |*entry| {
        if (entry.kind() != mld.report) continue;
        const body = entry.message();
        const records = _ip.get16(body, 6);
        var at: usize = 8;
        for (0..records) |_| {
            if (body[at] == mld.to_include and std.mem.eql(u8, body[at + 4 ..][0..16], &mdns.bytes)) left = true;
            at += 20;
        }
    }
    try testing.expect(left);
    _ = sb.CloseSocket(one);
    try rig.deinit();
}

// --- privacy addresses -----------------------------------------------------------

const privacy = @import("../nd/privacy.zig");

/// The temporary addresses of the interface, in their slots' order, and
/// how many.
fn temporaries(rig: *Rig, into: *[_ip6.addresses_max]*_ip6.InterfaceAddress) usize {
    var found: usize = 0;
    for (&rig.interface.ip6.addresses) |*entry| {
        if (entry.state == .unused or entry.temporary == 0) continue;
        into[found] = entry;
        found += 1;
    }
    return found;
}

/// The temporary address that is neither deprecated nor followed by a
/// newer one yet.
fn currentTemporary(rig: *Rig) ?*_ip6.InterfaceAddress {
    var found: [_ip6.addresses_max]*_ip6.InterfaceAddress = undefined;
    for (found[0..temporaries(rig, &found)]) |entry| {
        if (entry.renewed == 0 and (entry.state == .preferred or entry.state == .tentative)) return entry;
    }
    return null;
}

const day_us: u64 = 24 * 60 * 60 * 1_000_000;

test "privacy addresses: a temporary address beside the stable one, which connections going out take" {
    var rig = try Rig.init();
    rig.interface.ip6.privacy = 1;
    rig.ready();
    const made_at = rig.stack.fixed_time;
    advertise(&rig, 1800, 7 * 86400, 7 * 86400);
    const stable = _ip6.addressOf(rig.interface, global).?;
    try testing.expectEqual(@as(u8, 0), stable.temporary);
    const temporary = currentTemporary(&rig).?;
    try testing.expectEqual(_ip6.AddressState.tentative, temporary.state);
    try testing.expectEqual(@as(u8, 1), temporary.autoconf);
    try testing.expect(temporary.address.inPrefix(global, 64));
    try testing.expect(!temporary.address.eql(global));
    // Valid for two days, preferred for one less up to 0.4 of one.
    try testing.expectEqual(made_at + 2 * day_us, temporary.valid_until);
    try testing.expect(temporary.preferred_until <= made_at + day_us);
    try testing.expect(temporary.preferred_until >= made_at + day_us * 6 / 10);
    // Both checked; then the temporary one is the source going out, the
    // link-local one still on the link.
    rig.pass(2_100_000);
    try testing.expectEqual(_ip6.AddressState.preferred, stable.state);
    try testing.expectEqual(_ip6.AddressState.preferred, temporary.state);
    const far = address("2001:db8:2::1");
    try testing.expect(_inet.sourceFor(_inet.route(rig.stack, far, null).?, far).?.eql(temporary.address));
    try testing.expect(_inet.sourceFor(_inet.route(rig.stack, gateway, rig.interface).?, gateway).?.eql(own));
    // NetStatus sees which it is.
    var infos: [_ip6.addresses_max]bsd.Address6Info = undefined;
    const listed = rig.sb.GetNetworkStatistics(bsd.NETSTATUS_ADDRESSES6, &infos, @sizeOf(@TypeOf(infos)));
    var marked: u32 = 0;
    for (infos[0..@intCast(listed)]) |*info| {
        if (info.temporary != 0) {
            marked += 1;
            try testing.expect(std.mem.eql(u8, &info.address.s6_addr, &temporary.address.bytes));
        }
    }
    try testing.expectEqual(@as(u32, 1), marked);
    // The prefix advertised again: still the one.
    advertise(&rig, 1800, 7 * 86400, 7 * 86400);
    var all: [_ip6.addresses_max]*_ip6.InterfaceAddress = undefined;
    try testing.expectEqual(@as(usize, 1), temporaries(&rig, &all));
    try rig.deinit();
}

test "a temporary address is followed by a new one before it is deprecated, and goes when it ends" {
    var rig = try Rig.init();
    rig.interface.ip6.privacy = 1;
    rig.ready();
    advertise(&rig, 1800, 0xFFFF_FFFF, 0xFFFF_FFFF);
    rig.pass(2_100_000);
    const first = currentTemporary(&rig).?;
    const first_address = first.address;
    const first_preferred = first.preferred_until;
    const first_valid = first.valid_until;
    // Just before it stops being preferred, the next one is made.
    rig.leap(first_preferred - privacy.regenerate_us + 1 - rig.stack.fixed_time);
    var all: [_ip6.addresses_max]*_ip6.InterfaceAddress = undefined;
    try testing.expectEqual(@as(usize, 2), temporaries(&rig, &all));
    try testing.expectEqual(@as(u8, 1), first.renewed);
    rig.pass(2_100_000);
    const second = currentTemporary(&rig).?;
    try testing.expect(second != first);
    try testing.expect(!second.address.eql(first_address));
    try testing.expectEqual(_ip6.AddressState.preferred, second.state);
    // Then the first is deprecated, and the second taken - on the link,
    // since the router's day as a default is long over.
    rig.leap(first_preferred + 1 - rig.stack.fixed_time);
    try testing.expectEqual(_ip6.AddressState.deprecated, first.state);
    const near = address("2001:db8:1::5");
    try testing.expect(_inet.sourceFor(_inet.route(rig.stack, near, null).?, near).?.eql(second.address));
    // Valid two days from its making, then gone; the stable one stays.
    rig.leap(first_valid + 1 - rig.stack.fixed_time);
    try testing.expect(_ip6.addressOf(rig.interface, first_address) == null);
    try testing.expect(_ip6.addressOf(rig.interface, global) != null);
    try testing.expect(currentTemporary(&rig) != null);
    try rig.deinit();
}

test "a temporary address keeps to its prefix's lifetimes; turned off it goes, on it comes" {
    var rig = try Rig.init();
    rig.interface.ip6.privacy = 1;
    rig.ready();
    advertise(&rig, 1800, 3600, 1800);
    rig.pass(2_100_000);
    const stable = _ip6.addressOf(rig.interface, global).?;
    const temporary = currentTemporary(&rig).?;
    try testing.expectEqual(stable.preferred_until, temporary.preferred_until);
    try testing.expectEqual(stable.valid_until, temporary.valid_until);
    // A prefix about to stop being preferred makes none.
    advertise(&rig, 1800, 3600, 3);
    var all: [_ip6.addresses_max]*_ip6.InterfaceAddress = undefined;
    try testing.expectEqual(@as(usize, 1), temporaries(&rig, &all));

    const off = [_]sdk.utility.TagItem{ .{ .tag = bsd.IFA_PrivacyAddresses, .data = 0 }, .{} };
    try testing.expectEqual(@as(i32, 0), rig.sb.ConfigureInterfaceTagList("test", &off));
    try testing.expectEqual(@as(usize, 0), temporaries(&rig, &all));
    const far = address("2001:db8:2::1");
    try testing.expect(_inet.sourceFor(_inet.route(rig.stack, far, null).?, far).?.eql(global));
    advertise(&rig, 1800, 3600, 1800);
    try testing.expectEqual(@as(usize, 0), temporaries(&rig, &all));
    const on = [_]sdk.utility.TagItem{ .{ .tag = bsd.IFA_PrivacyAddresses, .data = 1 }, .{} };
    try testing.expectEqual(@as(i32, 0), rig.sb.ConfigureInterfaceTagList("test", &on));
    try testing.expectEqual(@as(usize, 1), temporaries(&rig, &all));
    try rig.deinit();
}

test "a temporary address another station has is made again with new bits, three times" {
    var rig = try Rig.init();
    rig.interface.ip6.privacy = 1;
    rig.ready();
    advertise(&rig, 1800, 86400, 86400);
    const temporary = currentTemporary(&rig).?;
    for (1..4) |tries| {
        const taken = temporary.address;
        rig.nd(peer, Address.all_nodes, _nd.neighbor_advertisement, _nd.flag_override, taken, _nd.option_target, peer_hardware);
        try testing.expectEqual(_ip6.AddressState.tentative, temporary.state);
        try testing.expectEqual(@as(u8, @intCast(tries)), temporary.counter);
        try testing.expect(!temporary.address.eql(taken));
        try testing.expect(temporary.address.inPrefix(global, 64));
    }
    // The fourth time: kept as a duplicate, and the prefix gets no other.
    rig.nd(peer, Address.all_nodes, _nd.neighbor_advertisement, _nd.flag_override, temporary.address, _nd.option_target, peer_hardware);
    try testing.expectEqual(_ip6.AddressState.duplicate, temporary.state);
    advertise(&rig, 1800, 86400, 86400);
    var all: [_ip6.addresses_max]*_ip6.InterfaceAddress = undefined;
    try testing.expectEqual(@as(usize, 1), temporaries(&rig, &all));
    try testing.expect(currentTemporary(&rig) == null);
    // The stable one is unharmed.
    rig.pass(2_100_000);
    try testing.expectEqual(_ip6.AddressState.preferred, _ip6.addressOf(rig.interface, global).?.state);
    try rig.deinit();
}

// --- addresses and routes set by hand ---------------------------------------------

fn in6(text: []const u8) bsd.in6_addr {
    return .{ .s6_addr = parse(text).?.bytes };
}

test "IPv6 routes by hand: through a router, on the link, a default, and taken away" {
    var rig = try Rig.init();
    rig.ready();
    const sb = rig.sb;
    const TagItem = sdk.utility.TagItem;
    // Through a link-local router, its interface the one link there is.
    const net9 = in6("2001:db8:9::");
    const router9 = in6("fe80::9");
    const through = [_]TagItem{
        .{ .tag = bsd.RTA_Destination6, .data = @intFromPtr(&net9) },
        .{ .tag = bsd.RTA_PrefixLength6, .data = 48 },
        .{ .tag = bsd.RTA_Gateway6, .data = @intFromPtr(&router9) },
        .{},
    };
    try testing.expectEqual(@as(i32, 0), sb.AddRouteTagList(&through));
    const in_net9 = address("2001:db8:9:1::5");
    const path = _inet.route(rig.stack, in_net9, null).?;
    try testing.expect(path.next_hop.eql(address("fe80::9")));
    try testing.expectEqual(rig.interface, path.interface);
    // On the link: it needs its interface.
    const net8 = in6("2001:db8:8::");
    var on_link = [_]TagItem{
        .{ .tag = bsd.RTA_Destination6, .data = @intFromPtr(&net8) },
        .{ .tag = bsd.RTA_PrefixLength6, .data = 64 },
        .{},
        .{},
    };
    try testing.expectEqual(@as(i32, -1), sb.AddRouteTagList(&on_link));
    try testing.expectEqual(bsd.EINVAL, sb.Errno());
    on_link[2] = .{ .tag = bsd.RTA_Interface, .data = @intFromPtr("nothere") };
    try testing.expectEqual(@as(i32, -1), sb.AddRouteTagList(&on_link));
    try testing.expectEqual(bsd.ENXIO, sb.Errno());
    on_link[2] = .{ .tag = bsd.RTA_Interface, .data = @intFromPtr("test") };
    try testing.expectEqual(@as(i32, 0), sb.AddRouteTagList(&on_link));
    const in_net8 = address("2001:db8:8::5");
    try testing.expect(_inet.route(rig.stack, in_net8, null).?.next_hop.eql(in_net8));
    // A default route; nowhere else to go before it.
    const far = address("2001:db8:2::1");
    try testing.expect(_inet.route(rig.stack, far, null) == null);
    const router7 = in6("fe80::7");
    const default = [_]TagItem{ .{ .tag = bsd.RTA_DefaultGateway6, .data = @intFromPtr(&router7) }, .{ .tag = bsd.RTA_Interface, .data = @intFromPtr("test") }, .{} };
    try testing.expectEqual(@as(i32, 0), sb.AddRouteTagList(&default));
    try testing.expect(_inet.route(rig.stack, far, null).?.next_hop.eql(address("fe80::7")));
    // A group is no router.
    const group = in6("ff02::1");
    const bad = [_]TagItem{ .{ .tag = bsd.RTA_DefaultGateway6, .data = @intFromPtr(&group) }, .{} };
    try testing.expectEqual(@as(i32, -1), sb.AddRouteTagList(&bad));

    // Taken away: by prefix, then every default route.
    const delete9 = [_]TagItem{ .{ .tag = bsd.RTA_Destination6, .data = @intFromPtr(&net9) }, .{ .tag = bsd.RTA_PrefixLength6, .data = 48 }, .{} };
    try testing.expectEqual(@as(i32, 0), sb.DeleteRouteTagList(&delete9));
    try testing.expect(_inet.route(rig.stack, in_net9, null).?.next_hop.eql(address("fe80::7")));
    try testing.expectEqual(@as(i32, -1), sb.DeleteRouteTagList(&delete9));
    try testing.expectEqual(bsd.ENXIO, sb.Errno());
    const defaults = [_]TagItem{ .{ .tag = bsd.RTA_DefaultGateway6, .data = 0 }, .{} };
    try testing.expectEqual(@as(i32, 0), sb.DeleteRouteTagList(&defaults));
    try testing.expect(_inet.route(rig.stack, far, null) == null);
    try rig.deinit();
}

test "an IPv6 address given at run time replaces the one given before" {
    var rig = try Rig.init();
    rig.ready();
    const sb = rig.sb;
    const TagItem = sdk.utility.TagItem;
    const first = in6("2001:db8:5::7");
    const set_first = [_]TagItem{ .{ .tag = bsd.IFA_Address6, .data = @intFromPtr(&first) }, .{} };
    try testing.expectEqual(@as(i32, 0), sb.ConfigureInterfaceTagList("test", &set_first));
    const made = _ip6.addressOf(rig.interface, address("2001:db8:5::7")).?;
    try testing.expectEqual(_ip6.AddressState.tentative, made.state);
    try testing.expectEqual(@as(u8, 64), made.prefix_length);
    rig.pass(2_100_000);
    try testing.expectEqual(_ip6.AddressState.preferred, made.state);
    const near = address("2001:db8:5::9");
    try testing.expect(_inet.route(rig.stack, near, null).?.next_hop.eql(near));
    try testing.expect(_inet.sourceFor(_inet.route(rig.stack, near, null).?, near).?.eql(address("2001:db8:5::7")));
    // Given again as it is: left alone, still preferred.
    try testing.expectEqual(@as(i32, 0), sb.ConfigureInterfaceTagList("test", &set_first));
    try testing.expectEqual(_ip6.AddressState.preferred, made.state);

    // Another, a host of its own: the first and its prefix go.
    const second = in6("2001:db8:6::1");
    const set_second = [_]TagItem{ .{ .tag = bsd.IFA_Address6, .data = @intFromPtr(&second) }, .{ .tag = bsd.IFA_Prefix6, .data = 128 }, .{} };
    try testing.expectEqual(@as(i32, 0), sb.ConfigureInterfaceTagList("test", &set_second));
    try testing.expect(_ip6.addressOf(rig.interface, address("2001:db8:5::7")) == null);
    try testing.expect(_inet.route(rig.stack, near, null) == null);
    try testing.expect(_ip6.addressOf(rig.interface, address("2001:db8:6::1")) != null);
    // `::`: none any more; the link-local one stays.
    const none = in6("::");
    const clear = [_]TagItem{ .{ .tag = bsd.IFA_Address6, .data = @intFromPtr(&none) }, .{} };
    try testing.expectEqual(@as(i32, 0), sb.ConfigureInterfaceTagList("test", &clear));
    try testing.expect(_ip6.addressOf(rig.interface, address("2001:db8:6::1")) == null);
    try testing.expect(_ip6.linkLocal(rig.interface) != null);
    // A group is no address.
    const group = in6("ff02::1");
    const bad = [_]TagItem{ .{ .tag = bsd.IFA_Address6, .data = @intFromPtr(&group) }, .{} };
    try testing.expectEqual(@as(i32, -1), sb.ConfigureInterfaceTagList("test", &bad));
    try testing.expectEqual(bsd.EINVAL, sb.Errno());
    try rig.deinit();
}
