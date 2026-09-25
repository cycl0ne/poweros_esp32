// SPDX-License-Identifier: MIT
//! Host tests of the timer heap and of ARP, on an interface whose link is
//! the test's own: what the stack hands it is recorded, and what the
//! network answers is written by the test. Time is whatever the test says
//! it is, since the timers take `now` from their caller.

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
const _arp = @import("../arp/_arp.zig");
const _timer = @import("../timer/_timer.zig");
const _ip = @import("../ip/_ip.zig");
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;

const testing = std.testing;

// --- the timer heap ---------------------------------------------------------

var fired_order: [8]u32 = @splat(0);
var fired_count: u32 = 0;

fn record(_: *StackBase, fired: *_timer.Timer, _: u64) void {
    fired_order[fired_count] = @truncate(fired.deadline);
    fired_count += 1;
}

test "the timers fire earliest first, and a cancelled one not at all" {
    var stack: StackBase = undefined;
    stack.timers = .{};
    stack.task = null;
    var timers: [6]_timer.Timer = @splat(.{ .fire = &record });
    const deadlines = [6]u64{ 50, 10, 40, 20, 60, 30 };
    for (&timers, deadlines) |*entry, deadline| try testing.expect(_timer.set(&stack, entry, deadline));
    _timer.cancel(&stack, &timers[2]);
    try testing.expectEqual(@as(?u64, 10), _timer.earliest(&stack));
    fired_count = 0;
    _timer.run(&stack, 35);
    try testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, fired_order[0..fired_count]);
    // Set again, a timer moves.
    try testing.expect(_timer.set(&stack, &timers[4], 45));
    _timer.run(&stack, 100);
    try testing.expectEqualSlices(u32, &.{ 10, 20, 30, 45, 50 }, fired_order[0..fired_count]);
    try testing.expectEqual(@as(?u64, null), _timer.earliest(&stack));
}

// --- a link the test watches ------------------------------------------------------

const Sent = struct {
    to: [6]u8,
    packet_type: u16,
    bytes: [128]u8,
    length: usize,
};

var sent: [16]Sent = undefined;
var sent_count: usize = 0;

fn capture(stack: *StackBase, _: *Interface, frame: *Frame, to: *const [6]u8, packet_type: u16) i32 {
    const bytes = frame.bytes();
    const length = @min(bytes.len, 128);
    sent[sent_count] = .{ .to = to.*, .packet_type = packet_type, .bytes = undefined, .length = bytes.len };
    @memcpy(sent[sent_count].bytes[0..length], bytes[0..length]);
    sent_count += 1;
    stack.frames.give(stack.sys_base, frame);
    return 0;
}

const own_hardware = [6]u8{ 0x02, 0, 0, 0, 0, 1 };
const peer_hardware = [6]u8{ 0x02, 0, 0, 0, 0, 2 };
const own_address: u32 = 0x0A00_0001;
const peer_address: u32 = 0x0A00_0002;

const Rig = struct {
    kub: *utility_library.UtilityBase,
    stack_lib: *exec.Library,
    sb: *SocketBase,
    stack: *StackBase,
    interface: *Interface,

    fn init() !Rig {
        const kub = try utility_library.setUp();
        const sys = kexec.SysBase.iface();
        const made = kexec.InitResident(kexec.SysBase, &bsdsocket.bsdsocket_library_tag, null) orelse return error.NoLibrary;
        const stack_lib: *exec.Library = @ptrCast(@alignCast(made));
        const sb: *SocketBase = @ptrCast(sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse return error.NoBase);
        const stack = _base.stackBase(stack_lib);
        const interface = _netif.free(stack).?;
        interface.* = .{
            .address = own_address,
            .netmask = 0xFFFF_FF00,
            .broadcast = 0x0A00_00FF,
            .mtu = 1500,
            .used = 1,
            .up = 1,
            .hardware = own_hardware,
            .transmit = &capture,
        };
        @memcpy(interface.name[0..4], "test");
        _ = _route.add(stack, own_address, 0xFFFF_FF00, 0, interface);
        sent_count = 0;
        return .{ .kub = kub, .stack_lib = stack_lib, .sb = sb, .stack = stack, .interface = interface };
    }

    fn deinit(rig: *Rig) !void {
        const sys = kexec.SysBase.iface();
        _arp.forget(rig.stack, rig.interface);
        rig.interface.* = .{};
        sys.CloseLibrary(rig.sb.lib());
        _ = sys.RemLibrary(rig.stack_lib);
        try utility_library.tearDown(rig.kub);
        kexec.deinit();
    }

    /// A datagram to the peer, as a program sends one.
    fn sendToPeer(rig: *Rig) i32 {
        const socket = rig.sb.Socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0);
        defer _ = rig.sb.CloseSocket(socket);
        var to: bsd.sockaddr_in = .{ .sin_port = bsd.htons(9), .sin_addr = .{ .s_addr = bsd.htonl(peer_address) } };
        return rig.sb.SendTo(socket, "data", 4, 0, to.anyConst(), @sizeOf(bsd.sockaddr_in));
    }

    /// An ARP packet from the network, handed to the stack.
    fn arrive(rig: *Rig, operation: u16, sender_hardware: [6]u8, sender: u32, target: u32, now: u64) void {
        const frame = rig.stack.frames.take(rig.stack.sys_base).?;
        const packet = frame.buffer[frame.start..][0.._arp.packet_bytes];
        frame.length = _arp.packet_bytes;
        _ip.put16(packet, 0, 1);
        _ip.put16(packet, 2, _ip.ethertype);
        packet[4] = 6;
        packet[5] = 4;
        _ip.put16(packet, 6, operation);
        packet[8..14].* = sender_hardware;
        _ip.put32(packet, 14, sender);
        packet[18..24].* = @splat(0);
        _ip.put32(packet, 24, target);
        _arp.input(rig.stack, rig.interface, frame, now);
    }
};

fn isRequestFor(entry: Sent, address: u32) bool {
    return entry.packet_type == _arp.ethertype and _ip.get16(&entry.bytes, 6) == 1 and _ip.get32(&entry.bytes, 24) == address;
}

test "a packet waits for the answer, and goes to the address that answered" {
    var rig = try Rig.init();
    try testing.expectEqual(@as(i32, 4), rig.sendToPeer());
    try testing.expectEqual(@as(usize, 1), sent_count);
    try testing.expect(isRequestFor(sent[0], peer_address));
    try testing.expectEqual(_arp.broadcast, sent[0].to);
    try testing.expectEqualSlices(u8, &own_hardware, sent[0].bytes[8..14]);

    rig.arrive(2, peer_hardware, peer_address, own_address, 100);
    try testing.expectEqual(@as(usize, 2), sent_count);
    try testing.expectEqual(_ip.ethertype, sent[1].packet_type);
    try testing.expectEqual(peer_hardware, sent[1].to);
    try testing.expectEqual(peer_address, _ip.get32(&sent[1].bytes, 16));

    // Resolved now: the next one goes at once.
    try testing.expectEqual(@as(i32, 4), rig.sendToPeer());
    try testing.expectEqual(@as(usize, 3), sent_count);
    try testing.expectEqual(peer_hardware, sent[2].to);
    try rig.deinit();
}

test "an unanswered address is asked five times, then held, then free again" {
    var rig = try Rig.init();
    _ = rig.sendToPeer();
    var now: u64 = 0;
    for (1.._arp.tries_max) |_| {
        now += _arp.retry_us;
        _timer.run(rig.stack, now);
    }
    try testing.expectEqual(@as(usize, _arp.tries_max), sent_count);
    for (sent[0..sent_count]) |entry| try testing.expect(isRequestFor(entry, peer_address));
    now += _arp.retry_us;
    _timer.run(rig.stack, now);
    try testing.expectEqual(@as(usize, _arp.tries_max), sent_count);
    try testing.expectEqual(@as(u32, 1), rig.stack.arp.dropped);
    // Held: sends fail at once, and nothing is asked.
    try testing.expectEqual(@as(i32, -1), rig.sendToPeer());
    try testing.expectEqual(bsd.EHOSTUNREACH, rig.sb.Errno());
    try testing.expectEqual(@as(usize, _arp.tries_max), sent_count);
    now += _arp.hold_us;
    _timer.run(rig.stack, now);
    _ = rig.sendToPeer();
    try testing.expectEqual(@as(usize, _arp.tries_max + 1), sent_count);
    try rig.deinit();
}

test "a question for our address is answered, and the asker learned" {
    var rig = try Rig.init();
    rig.arrive(1, peer_hardware, peer_address, own_address, 0);
    try testing.expectEqual(@as(usize, 1), sent_count);
    const answer = sent[0];
    try testing.expectEqual(peer_hardware, answer.to);
    try testing.expectEqual(@as(u16, 2), _ip.get16(&answer.bytes, 6));
    try testing.expectEqualSlices(u8, &own_hardware, answer.bytes[8..14]);
    try testing.expectEqual(own_address, _ip.get32(&answer.bytes, 14));
    try testing.expectEqual(peer_address, _ip.get32(&answer.bytes, 24));
    // Learned: a packet to it needs no question.
    _ = rig.sendToPeer();
    try testing.expectEqual(@as(usize, 2), sent_count);
    try testing.expectEqual(_ip.ethertype, sent[1].packet_type);
    // A question for someone else is not answered.
    rig.arrive(1, peer_hardware, peer_address, 0x0A00_0009, 0);
    try testing.expectEqual(@as(usize, 2), sent_count);
    try rig.deinit();
}

test "a peer heard from lives on; a silent one is checked, then forgotten" {
    var rig = try Rig.init();
    rig.arrive(2, peer_hardware, peer_address, own_address, 0);
    _arp.heard(rig.stack, rig.interface, peer_address, &peer_hardware);
    var now: u64 = _arp.life_us;
    _timer.run(rig.stack, now);
    try testing.expectEqual(@as(usize, 0), sent_count);
    now += _arp.life_us;
    _timer.run(rig.stack, now);
    try testing.expectEqual(@as(usize, 1), sent_count);
    try testing.expect(isRequestFor(sent[0], peer_address));
    try testing.expectEqual(peer_hardware, sent[0].to);
    now += _arp.check_us;
    _timer.run(rig.stack, now);
    // Forgotten: the next packet asks everyone again.
    _ = rig.sendToPeer();
    try testing.expectEqual(_arp.broadcast, sent[1].to);
    try rig.deinit();
}
