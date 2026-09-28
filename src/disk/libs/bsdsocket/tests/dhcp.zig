// SPDX-License-Identifier: MIT
//! Host tests of the DHCP client, with the test as the server: what the
//! client sends is caught at the interface's link, and the server's
//! answers - and other stations' ARP answers - are written by the test and
//! handed to the stack. Time is the test's.

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
const _route = @import("../route/_route.zig");
const _ip = @import("../ip/_ip.zig");
const _arp = @import("../arp/_arp.zig");
const _timer = @import("../timer/_timer.zig");
const _dhcp = @import("../dhcp/_dhcp.zig");
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;

const Address = @import("../ip6/address.zig").Address;
const testing = std.testing;

const own_hardware = [6]u8{ 0x02, 0, 0, 0, 0x12, 0x34 };
const server: u32 = 0x0A00_0001;
const offered: u32 = 0x0A00_0064;

// --- the link ----------------------------------------------------------------------

const Sent = struct { packet_type: u16, length: usize, bytes: [400]u8 };
var sent: [32]Sent = undefined;
var sent_count: usize = 0;

fn capture(stack: *StackBase, _: *Interface, frame: *Frame, _: *const [6]u8, packet_type: u16) i32 {
    const bytes = frame.bytes();
    const length = @min(bytes.len, 400);
    sent[sent_count] = .{ .packet_type = packet_type, .length = length, .bytes = undefined };
    @memcpy(sent[sent_count].bytes[0..length], bytes[0..length]);
    sent_count += 1;
    stack.frames.give(stack.sys_base, frame);
    return 0;
}

/// What a DHCP message the client sent says.
const Message = struct { kind: u8, xid: u32, ciaddr: u32, destination: u32, requested: u32, server_id: u32, hostname: [64]u8 = @splat(0) };

fn dhcpAt(index: usize) ?Message {
    const packet = sent[index].bytes[0..sent[index].length];
    if (sent[index].packet_type != _ip.ethertype or packet[9] != 17) return null;
    const message = packet[28..];
    var found: Message = .{ .kind = 0, .xid = _ip.get32(message, 4), .ciaddr = _ip.get32(message, 12), .destination = _ip.get32(packet, 16), .requested = 0, .server_id = 0 };
    var at: usize = 240;
    while (at + 1 < message.len and message[at] != 255) {
        if (message[at] == 0) {
            at += 1;
            continue;
        }
        const length = message[at + 1];
        switch (message[at]) {
            53 => found.kind = message[at + 2],
            50 => found.requested = _ip.get32(message, at + 2),
            54 => found.server_id = _ip.get32(message, at + 2),
            12 => @memcpy(found.hostname[0..length], message[at + 2 ..][0..length]),
            else => {},
        }
        at += 2 + length;
    }
    return found;
}

/// The last DHCP message the client sent.
fn lastDhcp() ?Message {
    var index = sent_count;
    while (index > 0) {
        index -= 1;
        if (dhcpAt(index)) |message| return message;
    }
    return null;
}

/// How many ARP probes (sender 0.0.0.0) for `address` went out.
fn probesFor(address: u32) usize {
    var count: usize = 0;
    for (sent[0..sent_count]) |entry| {
        if (entry.packet_type != _arp.ethertype) continue;
        if (_ip.get32(&entry.bytes, 14) == 0 and _ip.get32(&entry.bytes, 24) == address) count += 1;
    }
    return count;
}

const Rig = struct {
    kub: *utility_library.UtilityBase,
    lib: *exec.Library,
    stack: *StackBase,
    interface: *Interface,

    fn init() !Rig {
        const kub = try utility_library.setUp();
        const made = kexec.InitResident(kexec.SysBase, &bsdsocket.bsdsocket_library_tag, null) orelse return error.NoLibrary;
        const lib: *exec.Library = @ptrCast(@alignCast(made));
        const stack = _base.stackBase(lib);
        stack.no_task = 1;
        stack.fixed_time = 0;
        const interface = _netif.free(stack).?;
        interface.* = .{ .mtu = 1500, .used = 1, .up = 1, .dhcp = 1, .hardware = own_hardware, .transmit = &capture };
        @memcpy(interface.name[0..4], "eth0");
        sent_count = 0;
        return .{ .kub = kub, .lib = lib, .stack = stack, .interface = interface };
    }

    fn deinit(rig: *Rig) !void {
        const sys = kexec.SysBase.iface();
        _dhcp.stop(rig.stack, rig.interface);
        _arp.forget(rig.stack, rig.interface);
        _route.removeAll(rig.stack, rig.interface);
        rig.interface.* = .{};
        _ = sys.RemLibrary(rig.lib);
        try utility_library.tearDown(rig.kub);
        kexec.deinit();
    }

    fn advance(rig: *Rig, now: u64) void {
        rig.stack.fixed_time = now;
        _timer.run(rig.stack, now);
    }

    /// The server's answer of `kind`, to everyone.
    fn answer(rig: *Rig, kind: u8, xid: u32, yiaddr: u32, lease_s: u32) void {
        var packet: [400]u8 = @splat(0);
        const message = packet[28..];
        message[0] = 2;
        message[1] = 1;
        message[2] = 6;
        _ip.put32(message, 4, xid);
        _ip.put32(message, 16, yiaddr);
        message[28..34].* = own_hardware;
        _ip.put32(message, 236, 0x6382_5363);
        const options = [_]u8{
            53,  1,   kind,
            54,  4,   10,
            0,   0,   1,
            1,   4,   255,
            255, 255, 0,
            3,   4,   10,
            0,   0,   1,
            6,   8,   10,
            0,   0,   3,
            9,   9,   9,
            9,   15,  4,
            'l', 'a', 'b',
            '1', 51,  4,
        };
        @memcpy(message[240..][0..options.len], &options);
        _ip.put32(message, 240 + options.len, lease_s);
        message[240 + options.len + 4] = 255;
        const udp_length: usize = 8 + 300;
        packet[0] = 0x45;
        _ip.put16(&packet, 2, @intCast(20 + udp_length));
        packet[8] = 64;
        packet[9] = 17;
        _ip.put32(&packet, 12, server);
        _ip.put32(&packet, 16, bsd.INADDR_BROADCAST);
        _ip.put16(&packet, 10, _ip.finish(_ip.sum(0, packet[0..20])));
        _ip.put16(&packet, 20, 67);
        _ip.put16(&packet, 22, 68);
        _ip.put16(&packet, 24, @intCast(udp_length));
        rig.inject(packet[0 .. 20 + udp_length]);
    }

    /// Another station answering an ARP question: it has `address`.
    fn arpFromOther(rig: *Rig, address: u32) void {
        const frame = rig.stack.frames.take(rig.stack.sys_base).?;
        const packet = frame.room()[frame.start..][0.._arp.packet_bytes];
        frame.length = _arp.packet_bytes;
        _ip.put16(packet, 0, 1);
        _ip.put16(packet, 2, _ip.ethertype);
        packet[4] = 6;
        packet[5] = 4;
        _ip.put16(packet, 6, 2);
        packet[8..14].* = .{ 0x02, 0, 0, 0, 0x99, 0x99 };
        _ip.put32(packet, 14, address);
        packet[18..24].* = own_hardware;
        _ip.put32(packet, 24, 0);
        _arp.input(rig.stack, rig.interface, frame, rig.stack.fixed_time);
    }

    fn inject(rig: *Rig, bytes: []const u8) void {
        const frame = rig.stack.frames.take(rig.stack.sys_base).?;
        @memcpy(frame.room()[frame.start..][0..bytes.len], bytes);
        frame.length = @intCast(bytes.len);
        _ip.input(rig.stack, rig.interface, frame);
    }

    /// Discover, offer, request, ack, and the probes: bound.
    fn bind(rig: *Rig, lease_s: u32) !void {
        _dhcp.start(rig.stack, rig.interface);
        const first = lastDhcp().?;
        try testing.expectEqual(@as(u8, 1), first.kind);
        // The machine's name goes with the discover and the request.
        try testing.expectEqualStrings(std.mem.sliceTo(&rig.stack.hostname, 0), std.mem.sliceTo(&first.hostname, 0));
        try testing.expectEqual(bsd.INADDR_BROADCAST, first.destination);
        rig.answer(2, first.xid, offered, lease_s);
        const request = lastDhcp().?;
        try testing.expectEqual(@as(u8, 3), request.kind);
        try testing.expectEqual(offered, request.requested);
        try testing.expectEqual(server, request.server_id);
        rig.answer(5, request.xid, offered, lease_s);
        try testing.expectEqual(@as(usize, 1), probesFor(offered));
        try testing.expectEqual(@as(u32, 0), rig.interface.address);
        rig.advance(rig.stack.fixed_time + 1_000_000);
        try testing.expectEqual(@as(usize, 2), probesFor(offered));
        rig.advance(rig.stack.fixed_time + 1_000_000);
    }
};

test "discover, offer, request, ack, and the address checked before it is taken" {
    var rig = try Rig.init();
    try rig.bind(100);
    const interface = rig.interface;
    try testing.expectEqual(offered, interface.address);
    try testing.expectEqual(@as(u32, 0xFFFF_FF00), interface.netmask);
    try testing.expectEqual(@as(u8, 1), interface.bound);
    try testing.expectEqual(server, _route.defaultThrough(rig.stack, interface));
    try testing.expectEqual(@as(u32, 2), rig.stack.nameserver_count);
    for ([_]u32{ 0x0A00_0003, 0x0909_0909 }, rig.stack.nameservers[0..2]) |want, got| try testing.expect(got.eql(Address.fromV4(want)));
    try testing.expectEqualStrings("lab1", std.mem.sliceTo(&rig.stack.domain, 0));
    try rig.deinit();
}

test "at T1 the lease is renewed with the server, and a NAK starts again" {
    var rig = try Rig.init();
    try rig.bind(100);
    const bound_at = rig.stack.fixed_time;
    rig.advance(bound_at + 50_000_000);
    // Straight to the server: ARP asks where it is first.
    rig.arpFromOther(server);
    const renew = lastDhcp().?;
    try testing.expectEqual(@as(u8, 3), renew.kind);
    try testing.expectEqual(server, renew.destination);
    try testing.expectEqual(offered, renew.ciaddr);
    rig.answer(5, renew.xid, offered, 100);
    try testing.expectEqual(_dhcp.State.bound, rig.stack.dhcp.clients[1].state);
    try testing.expectEqual(offered, rig.interface.address);

    rig.advance(rig.stack.fixed_time + 50_000_000);
    const again = lastDhcp().?;
    rig.answer(6, again.xid, 0, 0);
    try testing.expectEqual(@as(u32, 0), rig.interface.address);
    try testing.expectEqual(@as(u8, 0), rig.interface.bound);
    try testing.expectEqual(@as(u8, 1), lastDhcp().?.kind);
    try rig.deinit();
}

test "an address someone already has is declined" {
    var rig = try Rig.init();
    _dhcp.start(rig.stack, rig.interface);
    const first = lastDhcp().?;
    rig.answer(2, first.xid, offered, 100);
    rig.answer(5, lastDhcp().?.xid, offered, 100);
    rig.arpFromOther(offered);
    var declined = false;
    for (0..sent_count) |index| {
        if (dhcpAt(index)) |message| {
            if (message.kind == 4) declined = true;
        }
    }
    try testing.expect(declined);
    try testing.expectEqual(@as(u8, 1), lastDhcp().?.kind);
    try testing.expectEqual(@as(u32, 0), rig.interface.address);
    try rig.deinit();
}

test "no server: a link-local address, the next one after a conflict" {
    var rig = try Rig.init();
    _dhcp.start(rig.stack, rig.interface);
    var rounds: usize = 0;
    while (rig.stack.dhcp.clients[1].link_local == 0 and rounds < 10) : (rounds += 1) {
        rig.advance(_timer.earliest(rig.stack).?);
    }
    const first = rig.stack.dhcp.clients[1].link_local;
    try testing.expectEqual(@as(u32, 0xA9FE), first >> 16);
    try testing.expectEqual(@as(usize, 1), probesFor(first));
    rig.arpFromOther(first);
    const second = rig.stack.dhcp.clients[1].link_local;
    try testing.expect(second != first and second >> 16 == 0xA9FE);
    rounds = 0;
    while (rig.interface.link_local == 0 and rounds < 10) : (rounds += 1) {
        rig.advance(_timer.earliest(rig.stack).?);
    }
    try testing.expectEqual(second, rig.interface.address);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), rig.interface.netmask);
    try testing.expectEqual(@as(usize, 3), probesFor(second));
    // DHCP goes on behind it, and a server that answers replaces it.
    rig.advance(_timer.earliest(rig.stack).?);
    const discover = lastDhcp().?;
    try testing.expectEqual(@as(u8, 1), discover.kind);
    rig.answer(2, discover.xid, offered, 100);
    rig.answer(5, lastDhcp().?.xid, offered, 100);
    rig.advance(rig.stack.fixed_time + 1_000_000);
    rig.advance(rig.stack.fixed_time + 1_000_000);
    try testing.expectEqual(offered, rig.interface.address);
    try testing.expectEqual(@as(u8, 0), rig.interface.link_local);
    try rig.deinit();
}
