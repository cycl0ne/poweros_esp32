// SPDX-License-Identifier: MIT
//! Host tests of IPv6 and ICMPv6, on an interface whose link is the
//! test's own and needs no neighbor discovery: what the stack sends is
//! recorded, and what the network sends is written by the test - base
//! header, extension headers, fragments - and handed to the interface as
//! a device would hand it.

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
const reassembly6 = @import("../ip6/reassembly.zig");
const Address = @import("../ip6/address.zig").Address;
const parse = @import("../ip6/address.zig").parse;
const crypto_init = @import("../../crypto/crypto_init.zig");
const _timer = @import("../timer/_timer.zig");
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;

const testing = std.testing;

const Sent = struct {
    to: [6]u8,
    packet_type: u16,
    bytes: [1400]u8,
    length: usize,
};

var sent: [16]Sent = undefined;
var sent_count: usize = 0;

fn capture(stack: *StackBase, _: *Interface, frame: *Frame, to: *const [6]u8, packet_type: u16) i32 {
    const bytes = frame.bytes();
    const length = @min(bytes.len, 1400);
    if (sent_count < sent.len) {
        sent[sent_count] = .{ .to = to.*, .packet_type = packet_type, .bytes = undefined, .length = bytes.len };
        @memcpy(sent[sent_count].bytes[0..length], bytes[0..length]);
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

/// Our link-local address, the EUI-64 of `own_hardware`.
const own = address("fe80::ff:fe00:1");
const peer = address("fe80::2");

/// Room for a packet being put back together, which is more than the
/// ROM's test RAM has: lent to exec for each test.
var lent: [256 * 1024]u8 align(16) = undefined;

const Rig = struct {
    kub: *utility_library.UtilityBase,
    region: *exec.MemHeader,
    stack_lib: *exec.Library,
    sb: *SocketBase,
    stack: *StackBase,
    interface: *Interface,

    fn init() !Rig {
        const kub = try utility_library.setUp();
        const sys = kexec.SysBase.iface();
        const region = sys.AddMemList(lent.len, exec.MEMF_ANY, 0, &lent, "lent").?;
        const made = kexec.InitResident(kexec.SysBase, &bsdsocket.bsdsocket_library_tag, null) orelse return error.NoLibrary;
        const stack_lib: *exec.Library = @ptrCast(@alignCast(made));
        const sb: *SocketBase = @ptrCast(sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse return error.NoBase);
        const stack = _base.stackBase(stack_lib);
        stack.no_task = 1;
        stack.fixed_time = 1_000_000;
        const interface = _netif.free(stack).?;
        interface.* = .{
            .mtu = 1500,
            .used = 1,
            .up = 1,
            .no_arp = 1,
            .hardware = own_hardware,
            .transmit = &capture,
        };
        @memcpy(interface.name[0..4], "test");
        interface.ip6.identifier = bsd.IFID_EUI64;
        _ip6.start(stack, interface);
        var rig: Rig = .{ .kub = kub, .region = region, .stack_lib = stack_lib, .sb = sb, .stack = stack, .interface = interface };
        // The link-local address checked, and its group reported.
        rig.pass(3_000_000);
        // No router on this link: it is not asked for again.
        _timer.cancel(stack, &interface.ip6.routers.timer);
        sent_count = 0;
        return rig;
    }

    /// `us` microseconds gone by, and every timer due run.
    fn pass(rig: *Rig, us: u64) void {
        const end = rig.stack.fixed_time + us;
        while (rig.stack.fixed_time < end) {
            rig.stack.fixed_time = @min(end, rig.stack.fixed_time + 100_000);
            _timer.run(rig.stack, rig.stack.fixed_time);
        }
    }

    fn deinit(rig: *Rig) !void {
        try rig.deinitWith(null);
    }

    /// The stack taken down, then `other` - a library the stack held -
    /// and nothing left behind.
    fn deinitWith(rig: *Rig, other: ?*exec.Library) !void {
        const sys = kexec.SysBase.iface();
        _ip6.stop(rig.stack, rig.interface);
        rig.interface.* = .{};
        sys.CloseLibrary(rig.sb.lib());
        _ = sys.RemLibrary(rig.stack_lib);
        if (other) |library| _ = sys.RemLibrary(library);
        // Everything taken from the lent region is back.
        try testing.expectEqual(@intFromPtr(rig.region.upper) - @intFromPtr(rig.region.lower), rig.region.free);
        sys.Remove(&rig.region.node);
        try utility_library.tearDown(rig.kub);
        kexec.deinit();
    }

    /// A packet from the network: `headers` (extension headers and all,
    /// the transport's header included) behind a base header naming
    /// `next_header`.
    fn arrive(rig: *Rig, source: Address, destination: Address, next_header: u8, body: []const u8) void {
        const frame = rig.stack.frames.take(rig.stack.sys_base).?;
        const packet = frame.buffer[frame.start..][0 .. _ip6.header_bytes + body.len];
        frame.length = @intCast(packet.len);
        _ip.put32(packet, 0, 0x6000_0000);
        _ip.put16(packet, 4, @intCast(body.len));
        packet[6] = next_header;
        packet[7] = 64;
        packet[8..24].* = source.bytes;
        packet[24..40].* = destination.bytes;
        @memcpy(packet[_ip6.header_bytes..], body);
        _netif.receive(rig.stack, rig.interface, frame, &peer_hardware, &own_hardware, _ip6.ethertype, 0);
    }
};

/// An ICMPv6 message of `kind` with `rest` behind its 4-byte header, the
/// checksum made for `source` and `destination`.
fn icmp6(into: []u8, source: Address, destination: Address, kind: u8, rest: []const u8) []u8 {
    const message = into[0 .. 4 + rest.len];
    message[0] = kind;
    message[1] = 0;
    _ip.put16(message, 2, 0);
    @memcpy(message[4..], rest);
    _ip.put16(message, 2, _ip.finish(_ip.sum(_inet.pseudoSum(source, destination, _ip6.protocol_icmp6, @intCast(message.len)), message)));
    return message;
}

/// An echo request's body: identifier, sequence, and data.
const echo_body = [_]u8{ 0x12, 0x34, 0, 1, 'p', 'i', 'n', 'g' };

fn sentSource(entry: *const Sent) Address {
    return .{ .bytes = entry.bytes[8..24].* };
}

fn sentDestination(entry: *const Sent) Address {
    return .{ .bytes = entry.bytes[24..40].* };
}

/// Whether the sent packet is a valid ICMPv6 message of `kind`, and its
/// checksum right.
fn isIcmp6(entry: *const Sent, kind: u8) bool {
    if (entry.packet_type != _ip6.ethertype or entry.bytes[6] != _ip6.protocol_icmp6) return false;
    const message = entry.bytes[_ip6.header_bytes..entry.length];
    if (message[0] != kind) return false;
    return _ip.finish(_ip.sum(_inet.pseudoSum(sentSource(entry), sentDestination(entry), _ip6.protocol_icmp6, @intCast(message.len)), message)) == 0;
}

test "the link-local address is the link's EUI-64 behind fe80::/64" {
    var rig = try Rig.init();
    try testing.expect(_ip6.linkLocal(rig.interface).?.eql(own));
    try testing.expect(_ip6.linkLocal(_netif.loopbackOf(rig.stack)) == null);
    try testing.expect(_ip6.addressOf(_netif.loopbackOf(rig.stack), Address.loopback) != null);
    try rig.deinit();
}

test "an echo request is answered, to a group too, from the link-local address" {
    var rig = try Rig.init();
    var buffer: [64]u8 = undefined;
    rig.arrive(peer, own, _ip6.protocol_icmp6, icmp6(&buffer, peer, own, _icmp6.echo_request, &echo_body));
    try testing.expectEqual(@as(usize, 1), sent_count);
    try testing.expect(isIcmp6(&sent[0], _icmp6.echo_reply));
    try testing.expect(sentSource(&sent[0]).eql(own));
    try testing.expect(sentDestination(&sent[0]).eql(peer));
    try testing.expectEqualSlices(u8, &echo_body, sent[0].bytes[44..52]);
    try testing.expectEqual(@as(u8, 64), sent[0].bytes[7]);

    rig.arrive(peer, Address.all_nodes, _ip6.protocol_icmp6, icmp6(&buffer, peer, Address.all_nodes, _icmp6.echo_request, &echo_body));
    try testing.expectEqual(@as(usize, 2), sent_count);
    try testing.expect(isIcmp6(&sent[1], _icmp6.echo_reply));
    try testing.expect(sentSource(&sent[1]).eql(own));
    try testing.expectEqual(@as(u32, 2), rig.stack.counts.icmp6_echoes_answered);
    try rig.deinit();
}

test "a packet for somebody else, from a group, or with a bad checksum is dropped" {
    var rig = try Rig.init();
    var buffer: [64]u8 = undefined;
    const stranger = address("fe80::99");
    rig.arrive(peer, stranger, _ip6.protocol_icmp6, icmp6(&buffer, peer, stranger, _icmp6.echo_request, &echo_body));
    rig.arrive(Address.all_nodes, own, _ip6.protocol_icmp6, icmp6(&buffer, Address.all_nodes, own, _icmp6.echo_request, &echo_body));
    const message = icmp6(&buffer, peer, own, _icmp6.echo_request, &echo_body);
    message[5] ^= 1;
    rig.arrive(peer, own, _ip6.protocol_icmp6, message);
    // ::1 never comes in from a link.
    rig.arrive(Address.loopback, own, _ip6.protocol_icmp6, icmp6(&buffer, Address.loopback, own, _icmp6.echo_request, &echo_body));
    try testing.expectEqual(@as(usize, 0), sent_count);
    try testing.expectEqual(@as(u32, 1), rig.stack.counts.ip6_not_ours);
    try testing.expectEqual(@as(u32, 2), rig.stack.counts.ip6_bad_header);
    try testing.expectEqual(@as(u32, 1), rig.stack.counts.icmp6_bad);
    try rig.deinit();
}

test "an unknown next header is a parameter problem pointing at it" {
    var rig = try Rig.init();
    rig.arrive(peer, own, 253, "whatever");
    try testing.expectEqual(@as(usize, 1), sent_count);
    try testing.expect(isIcmp6(&sent[0], _icmp6.parameter_problem));
    try testing.expectEqual(_ip6.problem_next_header, sent[0].bytes[41]);
    try testing.expectEqual(@as(u32, 6), _ip.get32(&sent[0].bytes, 44));
    // The packet quoted behind it, from its base header on.
    try testing.expectEqual(@as(u8, 0x60), sent[0].bytes[48]);
    try testing.expectEqual(@as(u8, 253), sent[0].bytes[48 + 6]);
    try testing.expectEqual(@as(u32, 1), rig.stack.counts.ip6_unknown_protocol);

    // Not for a packet sent to a group.
    rig.arrive(peer, Address.all_nodes, 253, "whatever");
    try testing.expectEqual(@as(usize, 1), sent_count);
    try rig.deinit();
}

test "options: padding and ignorable ones skipped, the others as their bits say" {
    var rig = try Rig.init();
    var body: [64]u8 = undefined;
    var message: [64]u8 = undefined;

    // A destination-options header with a Pad1, an option of type 0x1e
    // (skip) and PadN, then the echo request.
    const echo = icmp6(&message, peer, own, _icmp6.echo_request, &echo_body);
    body[0..8].* = .{ _ip6.protocol_icmp6, 0, 0, 0x1e, 1, 0, 1, 0 };
    @memcpy(body[8..][0..echo.len], echo);
    rig.arrive(peer, own, _ip6.destination_options, body[0 .. 8 + echo.len]);
    try testing.expectEqual(@as(usize, 1), sent_count);
    try testing.expect(isIcmp6(&sent[0], _icmp6.echo_reply));

    // Type 0x5e (bits 01): dropped without a word.
    body[3] = 0x5e;
    rig.arrive(peer, own, _ip6.destination_options, body[0 .. 8 + echo.len]);
    try testing.expectEqual(@as(usize, 1), sent_count);

    // Type 0x9e (bits 10): a parameter problem of code 2 at the option.
    body[3] = 0x9e;
    rig.arrive(peer, own, _ip6.destination_options, body[0 .. 8 + echo.len]);
    try testing.expectEqual(@as(usize, 2), sent_count);
    try testing.expect(isIcmp6(&sent[1], _icmp6.parameter_problem));
    try testing.expectEqual(_ip6.problem_option, sent[1].bytes[41]);
    try testing.expectEqual(@as(u32, 43), _ip.get32(&sent[1].bytes, 44));

    // Type 0xde (bits 11): the same, but not for a group.
    body[3] = 0xde;
    const to_group = icmp6(&message, peer, Address.all_nodes, _icmp6.echo_request, &echo_body);
    @memcpy(body[8..][0..to_group.len], to_group);
    rig.arrive(peer, Address.all_nodes, _ip6.destination_options, body[0 .. 8 + to_group.len]);
    try testing.expectEqual(@as(usize, 2), sent_count);
    // Bits 10 answer a group as well.
    body[3] = 0x9e;
    rig.arrive(peer, Address.all_nodes, _ip6.destination_options, body[0 .. 8 + to_group.len]);
    try testing.expectEqual(@as(usize, 3), sent_count);
    try testing.expect(sentSource(&sent[2]).eql(own));
    try rig.deinit();
}

test "a routing header with segments left, and hop-by-hop not first, are refused" {
    var rig = try Rig.init();
    var body: [64]u8 = undefined;
    var message: [64]u8 = undefined;
    const echo = icmp6(&message, peer, own, _icmp6.echo_request, &echo_body);
    // Routing type 4 with no segments left: ignored.
    body[0..8].* = .{ _ip6.protocol_icmp6, 0, 4, 0, 0, 0, 0, 0 };
    @memcpy(body[8..][0..echo.len], echo);
    rig.arrive(peer, own, _ip6.routing, body[0 .. 8 + echo.len]);
    try testing.expectEqual(@as(usize, 1), sent_count);
    try testing.expect(isIcmp6(&sent[0], _icmp6.echo_reply));
    // One segment left.
    body[3] = 1;
    rig.arrive(peer, own, _ip6.routing, body[0 .. 8 + echo.len]);
    try testing.expectEqual(@as(usize, 2), sent_count);
    try testing.expect(isIcmp6(&sent[1], _icmp6.parameter_problem));
    try testing.expectEqual(_ip6.problem_field, sent[1].bytes[41]);
    try testing.expectEqual(@as(u32, 43), _ip.get32(&sent[1].bytes, 44));
    // A hop-by-hop header behind a destination-options one.
    body[0..8].* = .{ _ip6.hop_by_hop, 0, 1, 4, 0, 0, 0, 0 };
    body[8..16].* = .{ _ip6.protocol_icmp6, 0, 1, 4, 0, 0, 0, 0 };
    @memcpy(body[16..][0..echo.len], echo);
    rig.arrive(peer, own, _ip6.destination_options, body[0 .. 16 + echo.len]);
    try testing.expectEqual(@as(usize, 3), sent_count);
    try testing.expectEqual(_ip6.problem_next_header, sent[2].bytes[41]);
    try testing.expectEqual(@as(u32, 40), _ip.get32(&sent[2].bytes, 44));
    try rig.deinit();
}

/// A fragment header and `data` behind it.
fn piece(into: []u8, next_header: u8, offset: u32, more: bool, identification: u32, data: []const u8) []u8 {
    into[0] = next_header;
    into[1] = 0;
    _ip.put16(into, 2, @intCast(offset | @intFromBool(more)));
    _ip.put32(into, 4, identification);
    @memcpy(into[8..][0..data.len], data);
    return into[0 .. 8 + data.len];
}

test "fragments are put back together, in any order" {
    var rig = try Rig.init();
    var rest: [1196]u8 = undefined;
    for (&rest, 0..) |*byte, at| byte.* = @truncate(at);
    @memcpy(rest[0..echo_body.len], &echo_body);
    var data: [1200]u8 = undefined;
    const echo = icmp6(&data, peer, own, _icmp6.echo_request, &rest);
    var buffer: [800]u8 = undefined;
    // The second half first.
    rig.arrive(peer, own, _ip6.fragment, piece(&buffer, _ip6.protocol_icmp6, 600, false, 7, echo[600..]));
    try testing.expectEqual(@as(usize, 0), sent_count);
    rig.arrive(peer, own, _ip6.fragment, piece(&buffer, _ip6.protocol_icmp6, 0, true, 7, echo[0..600]));
    try testing.expectEqual(@as(usize, 1), sent_count);
    try testing.expect(isIcmp6(&sent[0], _icmp6.echo_reply));
    try testing.expectEqual(@as(usize, _ip6.header_bytes + echo.len), sent[0].length);
    try testing.expectEqualSlices(u8, echo[4..], sent[0].bytes[44..sent[0].length]);
    try testing.expectEqual(@as(u32, 1), rig.stack.counts.ip6_reassembled);

    // An atomic fragment is the packet as it is.
    var small: [64]u8 = undefined;
    const short = icmp6(&small, peer, own, _icmp6.echo_request, &echo_body);
    rig.arrive(peer, own, _ip6.fragment, piece(&buffer, _ip6.protocol_icmp6, 0, false, 8, short));
    try testing.expectEqual(@as(usize, 2), sent_count);
    try testing.expect(isIcmp6(&sent[1], _icmp6.echo_reply));
    try rig.deinit();
}

test "overlapping fragments drop the packet; a stray one runs out of time" {
    var rig = try Rig.init();
    const rest: [44]u8 = @splat(0);
    var data: [64]u8 = undefined;
    const echo = icmp6(&data, peer, own, _icmp6.echo_request, &rest);
    var buffer: [128]u8 = undefined;
    rig.arrive(peer, own, _ip6.fragment, piece(&buffer, _ip6.protocol_icmp6, 0, true, 9, echo[0..24]));
    rig.arrive(peer, own, _ip6.fragment, piece(&buffer, _ip6.protocol_icmp6, 16, false, 9, echo[16..]));
    try testing.expectEqual(@as(u32, 1), rig.stack.counts.ip6_reassembly_dropped);
    try testing.expectEqual(@as(usize, 0), sent_count);
    for (rig.stack.reassembly6.slots) |slot| try testing.expectEqual(@as(u8, 0), slot.used);

    // A first piece alone: after 60 seconds a time-exceeded quotes it.
    rig.arrive(peer, own, _ip6.fragment, piece(&buffer, _ip6.protocol_icmp6, 0, true, 10, echo[0..24]));
    rig.stack.fixed_time += reassembly6.timeout_us;
    _timer.run(rig.stack, rig.stack.fixed_time);
    try testing.expectEqual(@as(usize, 1), sent_count);
    try testing.expect(isIcmp6(&sent[0], _icmp6.time_exceeded));
    try testing.expectEqual(_icmp6.code_reassembly, sent[0].bytes[41]);
    try testing.expectEqual(@as(u8, _ip6.fragment), sent[0].bytes[48 + 6]);
    try testing.expectEqual(@as(u32, 2), rig.stack.counts.ip6_reassembly_dropped);

    // A middle piece of the wrong length is a parameter problem.
    rig.arrive(peer, own, _ip6.fragment, piece(&buffer, _ip6.protocol_icmp6, 8, true, 11, echo[8..13]));
    try testing.expectEqual(@as(usize, 2), sent_count);
    try testing.expect(isIcmp6(&sent[1], _icmp6.parameter_problem));
    try testing.expectEqual(@as(u32, 4), _ip.get32(&sent[1].bytes, 44));
    try rig.deinit();
}

test "a packet-too-big lowers the path MTU, never below 1280, for ten minutes" {
    var rig = try Rig.init();
    const far = address("2001:db8::1");
    var quote: [4 + 48]u8 = @splat(0);
    _ip.put32(&quote, 0, 1400);
    quote[4] = 0x60;
    quote[4 + 8 ..][0..16].* = own.bytes;
    quote[4 + 24 ..][0..16].* = far.bytes;
    var buffer: [64]u8 = undefined;
    rig.arrive(peer, own, _ip6.protocol_icmp6, icmp6(&buffer, peer, own, _icmp6.packet_too_big, &quote));
    try testing.expectEqual(@as(u32, 1400), _ip6.pathMtu(rig.stack, far, 1500));
    // Lower, and then an attempt below the least.
    _ip.put32(&quote, 0, 600);
    rig.arrive(peer, own, _ip6.protocol_icmp6, icmp6(&buffer, peer, own, _icmp6.packet_too_big, &quote));
    try testing.expectEqual(@as(u32, 1280), _ip6.pathMtu(rig.stack, far, 1500));
    // A higher report does not raise it.
    _ip.put32(&quote, 0, 1450);
    rig.arrive(peer, own, _ip6.protocol_icmp6, icmp6(&buffer, peer, own, _icmp6.packet_too_big, &quote));
    try testing.expectEqual(@as(u32, 1280), _ip6.pathMtu(rig.stack, far, 1500));
    rig.stack.fixed_time += _ip6.path_mtu_timeout_us;
    try testing.expectEqual(@as(u32, 1500), _ip6.pathMtu(rig.stack, far, 1500));
    try rig.deinit();
}

test "errors are held to the rate limit" {
    var rig = try Rig.init();
    for (0.._icmp6.burst + 3) |_| rig.arrive(peer, own, 253, "x");
    try testing.expectEqual(@as(usize, _icmp6.burst), sent_count);
    try testing.expectEqual(@as(u32, 3), rig.stack.counts.icmp6_errors_limited);
    rig.stack.fixed_time += 2 * _icmp6.refill_us;
    for (0..3) |_| rig.arrive(peer, own, 253, "x");
    try testing.expectEqual(@as(usize, _icmp6.burst + 2), sent_count);
    try rig.deinit();
}

test "a datagram to a port nobody has is answered port-unreachable" {
    var rig = try Rig.init();
    var datagram: [12]u8 = .{ 0x30, 0x39, 0, 9, 0, 12, 0, 0, 'd', 'a', 't', 'a' };
    _ip.put16(&datagram, 6, _ip.finish(_ip.sum(_inet.pseudoSum(peer, own, @intCast(bsd.IPPROTO_UDP), 12), &datagram)));
    rig.arrive(peer, own, @intCast(bsd.IPPROTO_UDP), &datagram);
    try testing.expectEqual(@as(usize, 1), sent_count);
    try testing.expect(isIcmp6(&sent[0], _icmp6.destination_unreachable));
    try testing.expectEqual(_icmp6.code_port, sent[0].bytes[41]);
    try testing.expectEqual(@as(u32, 1), rig.stack.counts.udp_no_port);
    // Without a checksum it is not even looked at.
    _ip.put16(&datagram, 6, 0);
    rig.arrive(peer, own, @intCast(bsd.IPPROTO_UDP), &datagram);
    try testing.expectEqual(@as(usize, 1), sent_count);
    try testing.expectEqual(@as(u32, 1), rig.stack.counts.udp_bad);
    try rig.deinit();
}

test "an echo to ::1 goes around lo0 and comes back" {
    var rig = try Rig.init();
    const lo = _netif.loopbackOf(rig.stack);
    const path = _inet.route(rig.stack, Address.loopback, null).?;
    try testing.expectEqual(lo, path.interface);
    try testing.expect(_inet.sourceFor(path, Address.loopback).?.eql(Address.loopback));
    // Our own link-local goes over lo0 too.
    try testing.expectEqual(lo, _inet.route(rig.stack, own, null).?.interface);
    const frame = rig.stack.frames.take(rig.stack.sys_base).?;
    var buffer: [64]u8 = undefined;
    const echo = icmp6(&buffer, Address.loopback, Address.loopback, _icmp6.echo_request, &echo_body);
    @memcpy(frame.room()[frame.start..][0..echo.len], echo);
    frame.length = @intCast(echo.len);
    try testing.expectEqual(@as(i32, 0), _ip6.output(rig.stack, frame, Address.loopback, Address.loopback, _ip6.protocol_icmp6, 64, path));
    // The request came in and was answered, and the answer came in too.
    try testing.expectEqual(@as(u32, 1), rig.stack.counts.icmp6_echoes_answered);
    try testing.expectEqual(@as(u32, 2), rig.stack.counts.icmp6_received);
    try testing.expectEqual(@as(usize, 0), sent_count);
    try rig.deinit();
}

test "sources: of the destination's scope, and routes on a prefix" {
    var rig = try Rig.init();
    const global = address("2001:db8:1::ff:fe00:1");
    _ = _ip6.addAddress(rig.stack, rig.interface, global, 64, .preferred).?;
    // An address's prefix is not on the link unless a route says so.
    try testing.expect(_inet.route(rig.stack, address("2001:db8:1::5"), null) == null);
    try testing.expect(@import("../route6/_route6.zig").set(rig.stack, rig.interface, global, 64, Address.any, .manual, 0));
    const on_link = address("2001:db8:1::5");
    const path = _inet.route(rig.stack, on_link, null).?;
    try testing.expectEqual(rig.interface, path.interface);
    try testing.expect(_inet.sourceFor(path, on_link).?.eql(global));
    try testing.expect(_inet.sourceFor(_inet.route(rig.stack, peer, null).?, peer).?.eql(own));
    try testing.expect(_inet.route(rig.stack, address("2001:db8:2::5"), null) == null);
    // A deprecated address loses to a preferred one.
    const other = address("2001:db8:1::2:1");
    const entry = _ip6.addAddress(rig.stack, rig.interface, other, 64, .preferred).?;
    try testing.expect(_inet.sourceFor(path, address("2001:db8:1::2:5")).?.eql(other));
    entry.state = .deprecated;
    try testing.expect(_inet.sourceFor(path, address("2001:db8:1::2:5")).?.eql(global));
    try rig.deinit();
}

test "a stable identifier is SHA-256 over prefix, link address, counter and secret" {
    var rig = try Rig.init();
    const sys = kexec.SysBase.iface();
    const made = kexec.InitResident(kexec.SysBase, &crypto_init.crypto_library_tag, null) orelse return error.NoLibrary;
    const crypto_lib: *exec.Library = @ptrCast(@alignCast(made));
    rig.stack.crypto = @ptrCast(sys.OpenLibrary(sdk.crypto.CRYPTONAME, 1) orelse return error.NoCrypto);
    rig.interface.ip6.identifier = bsd.IFID_STABLE;
    for (&rig.interface.ip6.secret, 0..) |*byte, at| byte.* = @intCast(at);

    const made_address = _ip6.addressFor(rig.stack, rig.interface, &_ip6.link_local_prefix, 0);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&_ip6.link_local_prefix);
    hash.update(&own_hardware);
    hash.update(&[_]u8{0});
    hash.update(&rig.interface.ip6.secret);
    const digest = hash.finalResult();
    try testing.expectEqualSlices(u8, &_ip6.link_local_prefix, made_address.bytes[0..8]);
    try testing.expectEqualSlices(u8, digest[0..8], made_address.bytes[8..16]);
    // Another counter, another identifier; another prefix, too.
    try testing.expect(!_ip6.addressFor(rig.stack, rig.interface, &_ip6.link_local_prefix, 1).eql(made_address));
    const prefix = [8]u8{ 0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 0 };
    try testing.expect(!std.mem.eql(u8, _ip6.addressFor(rig.stack, rig.interface, &prefix, 0).bytes[8..16], made_address.bytes[8..16]));

    try testing.expect(_ip6.isReservedIdentifier(@splat(0)));
    try testing.expect(_ip6.isReservedIdentifier(.{ 0xfd, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x80 }));
    try testing.expect(_ip6.isReservedIdentifier(.{ 0x02, 0x00, 0x5e, 0xff, 0xfe, 0, 0x52, 0x13 }));
    try testing.expect(!_ip6.isReservedIdentifier(.{ 0xfd, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f }));

    // The stack closes crypto.library as it goes.
    try rig.deinitWith(crypto_lib);
}

test "without crypto.library a stable interface takes its EUI-64" {
    var rig = try Rig.init();
    rig.interface.ip6.identifier = bsd.IFID_STABLE;
    try testing.expect(_ip6.addressFor(rig.stack, rig.interface, &_ip6.link_local_prefix, 0).eql(own));
    try rig.deinit();
}

test "a reply larger than the path goes in fragments that put back together" {
    var rig = try Rig.init();
    // A path of 1280, IPv6's least.
    _ = _ip6.learnMtu(rig.stack, peer, 1280, rig.stack.fixed_time);
    var rest: [2996]u8 = undefined;
    for (&rest, 0..) |*byte, at| byte.* = @truncate(at *% 7);
    rest[0..4].* = .{ 0x12, 0x34, 0, 9 };
    var data: [3000]u8 = undefined;
    const echo = icmp6(&data, peer, own, _icmp6.echo_request, &rest);
    var buffer: [1300]u8 = undefined;
    // The request comes in three fragments.
    rig.arrive(peer, own, _ip6.fragment, piece(&buffer, _ip6.protocol_icmp6, 0, true, 21, echo[0..1200]));
    rig.arrive(peer, own, _ip6.fragment, piece(&buffer, _ip6.protocol_icmp6, 1200, true, 21, echo[1200..2400]));
    rig.arrive(peer, own, _ip6.fragment, piece(&buffer, _ip6.protocol_icmp6, 2400, false, 21, echo[2400..]));
    // The reply: fragments of at most 1280 bytes, one identification, in
    // order, the last without M.
    try testing.expectEqual(@as(usize, 3), sent_count);
    var whole: [3000]u8 = undefined;
    var filled: usize = 0;
    const id = _ip.get32(&sent[0].bytes, 44);
    for (sent[0..sent_count], 0..) |*entry, index| {
        try testing.expect(entry.length <= 1280);
        try testing.expectEqual(_ip6.fragment, entry.bytes[6]);
        try testing.expectEqual(_ip6.protocol_icmp6, entry.bytes[40]);
        try testing.expectEqual(id, _ip.get32(&entry.bytes, 44));
        const word = _ip.get16(&entry.bytes, 42);
        try testing.expectEqual(@as(usize, filled), word & 0xFFF8);
        try testing.expectEqual(index + 1 < sent_count, word & 1 != 0);
        const part = entry.bytes[48..entry.length];
        @memcpy(whole[filled..][0..part.len], part);
        filled += part.len;
    }
    try testing.expectEqual(@as(usize, 3000), filled);
    try testing.expectEqual(_icmp6.echo_reply, whole[0]);
    try testing.expectEqualSlices(u8, echo[4..], whole[4..3000]);
    // Its checksum is the whole message's.
    try testing.expectEqual(@as(u16, 0), _ip.finish(_ip.sum(_inet.pseudoSum(own, peer, _ip6.protocol_icmp6, 3000), &whole)));
    try testing.expectEqual(@as(u32, 3), rig.stack.counts.ip6_fragments_sent);
    try rig.deinit();
}
