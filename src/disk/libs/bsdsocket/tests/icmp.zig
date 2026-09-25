// SPDX-License-Identifier: MIT
//! Host tests of what the stack does with packets as they come: ICMP
//! echoes and errors, socket events, sockets handed between openers,
//! fragments put back together - and packets written to be hostile, each
//! of which must be dropped and counted, never read past its end, and
//! leave no frame behind.
//!
//! The packets are handed to IPv4 input on `lo0` directly, as if a device
//! had taken them in. Putting a datagram back together takes 64 KiB, more
//! than the ROM's test RAM has, so these tests lend exec a region of
//! their own.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const TagItem = sdk.utility.TagItem;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const bsdsocket = @import("../bsdsocket_init.zig");
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const _frame = @import("../frame/_frame.zig");
const _netif = @import("../netif/_netif.zig");
const _ip = @import("../ip/_ip.zig");
const _icmp = @import("../icmp/_icmp.zig");
const _arp = @import("../arp/_arp.zig");
const _timer = @import("../timer/_timer.zig");
const reassembly = @import("../ip/reassembly.zig");
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;

const testing = std.testing;

var lent: [512 * 1024]u8 align(16) = undefined;

const Rig = struct {
    kub: *utility_library.UtilityBase,
    region: *exec.MemHeader,
    stack_lib: *exec.Library,
    stack: *StackBase,

    fn init() !Rig {
        const kub = try utility_library.setUp();
        const sys = kexec.SysBase.iface();
        const region = sys.AddMemList(lent.len, exec.MEMF_ANY, 0, &lent, "lent").?;
        const made = kexec.InitResident(kexec.SysBase, &bsdsocket.bsdsocket_library_tag, null) orelse return error.NoLibrary;
        const stack_lib: *exec.Library = @ptrCast(@alignCast(made));
        return .{ .kub = kub, .region = region, .stack_lib = stack_lib, .stack = _base.stackBase(stack_lib) };
    }

    fn open(rig: *Rig) !*SocketBase {
        _ = rig;
        return @ptrCast(kexec.SysBase.iface().OpenLibrary(bsd.SOCKETNAME, 1) orelse return error.NoBase);
    }

    fn deinit(rig: *Rig) !void {
        const sys = kexec.SysBase.iface();
        _ = sys.RemLibrary(rig.stack_lib);
        // Everything taken from the lent region is back.
        try testing.expectEqual(@intFromPtr(rig.region.upper) - @intFromPtr(rig.region.lower), rig.region.free);
        sys.Remove(&rig.region.node);
        try utility_library.tearDown(rig.kub);
        kexec.deinit();
    }

    /// `bytes`, an IPv4 packet, in on lo0.
    fn inject(rig: *Rig, bytes: []const u8) void {
        const stack = rig.stack;
        const frame = stack.frames.take(stack.sys_base).?;
        @memcpy(frame.room()[frame.start..][0..bytes.len], bytes);
        frame.length = @intCast(bytes.len);
        _ip.input(stack, _netif.loopbackOf(stack), frame);
    }
};

fn udpSocket(sb: *SocketBase, port: u16) !i32 {
    const socket = sb.Socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    if (socket < 0) return error.NoSocket;
    if (port != 0) {
        var here: bsd.sockaddr_in = .{ .sin_port = bsd.htons(port), .sin_addr = .{ .s_addr = bsd.htonl(bsd.INADDR_LOOPBACK) } };
        if (sb.Bind(socket, here.anyConst(), @sizeOf(bsd.sockaddr_in)) < 0) return error.NoBind;
    }
    return socket;
}

fn loopback(port: u16) bsd.sockaddr_in {
    return .{ .sin_port = bsd.htons(port), .sin_addr = .{ .s_addr = bsd.htonl(bsd.INADDR_LOOPBACK) } };
}

/// An IPv4 header written at the front of `into`, for `payload_length`
/// bytes behind it, its checksum made.
fn ipHeader(into: []u8, protocol: u8, identification: u16, fragment: u16, payload_length: usize) void {
    into[0] = 0x45;
    into[1] = 0;
    _ip.put16(into, 2, @intCast(20 + payload_length));
    _ip.put16(into, 4, identification);
    _ip.put16(into, 6, fragment);
    into[8] = 64;
    into[9] = protocol;
    _ip.put16(into, 10, 0);
    _ip.put32(into, 12, bsd.INADDR_LOOPBACK);
    _ip.put32(into, 16, bsd.INADDR_LOOPBACK);
    _ip.put16(into, 10, _ip.finish(_ip.sum(0, into[0..20])));
}

// --- ICMP -----------------------------------------------------------------------

test "an echo request is answered, and a raw socket sees both" {
    var rig = try Rig.init();
    const sb = try rig.open();
    const raw = sb.Socket(bsd.PF_INET, bsd.SOCK_RAW, bsd.IPPROTO_ICMP);
    try testing.expect(raw >= 0);
    var echo: [12]u8 = .{ _icmp.echo_request, 0, 0, 0, 0x12, 0x34, 0, 1, 'p', 'i', 'n', 'g' };
    _ip.put16(&echo, 2, _ip.finish(_ip.sum(0, &echo)));
    var to = loopback(0);
    try testing.expectEqual(@as(i32, echo.len), sb.SendTo(raw, &echo, echo.len, 0, to.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(@as(u32, 1), rig.stack.counts.icmp_echoes_answered);

    var buffer: [64]u8 = undefined;
    // First the request itself, then the answer, each with its IPv4 header.
    try testing.expectEqual(@as(i32, 32), sb.Recv(raw, &buffer, buffer.len, 0));
    try testing.expectEqual(_icmp.echo_request, buffer[20]);
    try testing.expectEqual(@as(i32, 32), sb.Recv(raw, &buffer, buffer.len, 0));
    try testing.expectEqual(_icmp.echo_reply, buffer[20]);
    try testing.expectEqualSlices(u8, echo[4..], buffer[24..32]);
    try testing.expectEqual(@as(u16, 0), _ip.finish(_ip.sum(0, buffer[20..32])));
    kexec.SysBase.iface().CloseLibrary(sb.lib());
    try rig.deinit();
}

test "a datagram to a closed port is refused, and the sender told" {
    var rig = try Rig.init();
    const sb = try rig.open();
    const socket = try udpSocket(sb, 0);
    var nobody = loopback(9999);
    try testing.expectEqual(@as(i32, 1), sb.SendTo(socket, "x", 1, 0, nobody.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(@as(u32, 1), rig.stack.counts.icmp_errors_sent);
    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(i32, -1), sb.Recv(socket, &buffer, buffer.len, 0));
    try testing.expectEqual(bsd.ECONNREFUSED, sb.Errno());
    // Told once.
    var never: i32 = 1;
    _ = sb.IoctlSocket(socket, bsd.FIONBIO, &never);
    try testing.expectEqual(@as(i32, -1), sb.Recv(socket, &buffer, buffer.len, 0));
    try testing.expectEqual(bsd.EWOULDBLOCK, sb.Errno());

    // Nothing answers a datagram sent to many.
    const on: i32 = 1;
    _ = sb.SetSockOpt(socket, bsd.SOL_SOCKET, bsd.SO_BROADCAST, &on, @sizeOf(i32));
    var everyone: bsd.sockaddr_in = .{ .sin_port = bsd.htons(9999), .sin_addr = .{ .s_addr = bsd.htonl(0x7FFF_FFFF) } };
    _ = sb.SendTo(socket, "x", 1, 0, everyone.anyConst(), @sizeOf(bsd.sockaddr_in));
    try testing.expectEqual(@as(u32, 1), rig.stack.counts.icmp_errors_sent);
    kexec.SysBase.iface().CloseLibrary(sb.lib());
    try rig.deinit();
}

// --- events and handing over ---------------------------------------------------

test "a socket tells of the events it asked for, on the event signal" {
    var rig = try Rig.init();
    const sb = try rig.open();
    const sys = kexec.SysBase.iface();
    const tags = [_]TagItem{ .{ .tag = bsd.SBTM_SETVAL(bsd.SBTC_SIGEVENTMASK), .data = exec.SIGBREAKF_CTRL_E }, .{} };
    try testing.expectEqual(@as(i32, 0), sb.SocketBaseTagList(&tags));
    const socket = try udpSocket(sb, 7200);
    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_E);
    const mask: i32 = @bitCast(bsd.FD_READ | bsd.FD_WRITE);
    try testing.expectEqual(@as(i32, 0), sb.SetSockOpt(socket, bsd.SOL_SOCKET, bsd.SO_EVENTMASK, &mask, @sizeOf(i32)));
    try testing.expect(sys.SetSignal(0, exec.SIGBREAKF_CTRL_E) & exec.SIGBREAKF_CTRL_E != 0);
    var events: u32 = 0;
    try testing.expectEqual(socket, sb.GetSocketEvents(&events));
    try testing.expectEqual(bsd.FD_WRITE, events);
    try testing.expectEqual(@as(i32, -1), sb.GetSocketEvents(&events));

    const sender = try udpSocket(sb, 0);
    var to = loopback(7200);
    _ = sb.SendTo(sender, "x", 1, 0, to.anyConst(), @sizeOf(bsd.sockaddr_in));
    try testing.expect(sys.SetSignal(0, exec.SIGBREAKF_CTRL_E) & exec.SIGBREAKF_CTRL_E != 0);
    try testing.expectEqual(socket, sb.GetSocketEvents(&events));
    try testing.expectEqual(bsd.FD_READ, events);
    sys.CloseLibrary(sb.lib());
    try rig.deinit();
}

test "a socket handed over keeps its datagrams, and goes to the one who takes it" {
    var rig = try Rig.init();
    const giver = try rig.open();
    const taker = try rig.open();
    const socket = try udpSocket(giver, 7300);
    var to = loopback(7300);
    _ = giver.SendTo(try udpSocket(giver, 0), "kept", 4, 0, to.anyConst(), @sizeOf(bsd.sockaddr_in));
    const id = giver.ReleaseSocket(socket, bsd.UNIQUE_ID);
    try testing.expect(id > 0);
    try testing.expectEqual(@as(i32, -1), giver.CloseSocket(socket));
    try testing.expectEqual(@as(i32, -1), giver.ReleaseSocket(try udpSocket(giver, 0), id));
    try testing.expectEqual(bsd.EINVAL, giver.Errno());

    try testing.expectEqual(@as(i32, -1), taker.ObtainSocket(id, bsd.PF_INET, bsd.SOCK_RAW, 0));
    const taken = taker.ObtainSocket(id, bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    try testing.expect(taken >= 0);
    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(i32, 4), taker.Recv(taken, &buffer, buffer.len, 0));
    try testing.expectEqual(@as(i32, -1), taker.ObtainSocket(id, bsd.PF_INET, bsd.SOCK_DGRAM, 0));

    // One handed over and never taken goes with the library.
    _ = giver.ReleaseSocket(try udpSocket(giver, 7301), 77);
    const sys = kexec.SysBase.iface();
    sys.CloseLibrary(taker.lib());
    sys.CloseLibrary(giver.lib());
    try rig.deinit();
}

// --- fragments -----------------------------------------------------------------------

/// A UDP datagram of `data_length` bytes to port 7400, cut into IPv4
/// fragments of `piece` bytes of payload each, into `into`; the pieces'
/// starts and lengths.
const Piece = struct { start: usize, length: usize };

fn fragments(into: []u8, pieces: []Piece, data_length: usize, piece: usize, identification: u16) usize {
    var datagram: [4096]u8 = undefined;
    const udp_length = 8 + data_length;
    _ip.put16(&datagram, 0, 5555);
    _ip.put16(&datagram, 2, 7400);
    _ip.put16(&datagram, 4, @intCast(udp_length));
    _ip.put16(&datagram, 6, 0);
    for (datagram[8..udp_length], 0..) |*byte, index| byte.* = @truncate(index * 7);
    var at: usize = 0;
    var count: usize = 0;
    var offset: usize = 0;
    while (offset < udp_length) : (count += 1) {
        const length = @min(piece, udp_length - offset);
        const more: u16 = if (offset + length < udp_length) _ip.flag_more else 0;
        ipHeader(into[at..], @intCast(bsd.IPPROTO_UDP), identification, more | @as(u16, @intCast(offset / 8)), length);
        @memcpy(into[at + 20 ..][0..length], datagram[offset..][0..length]);
        pieces[count] = .{ .start = at, .length = 20 + length };
        at += 20 + length;
        offset += length;
    }
    return count;
}

test "fragments in any order make the datagram again" {
    var rig = try Rig.init();
    const sb = try rig.open();
    const socket = try udpSocket(sb, 7400);
    var packets: [8192]u8 = undefined;
    var pieces: [8]Piece = undefined;
    const count = fragments(&packets, &pieces, 3000, 1200, 1);
    try testing.expectEqual(@as(usize, 3), count);
    for ([_]usize{ 2, 0, 1 }) |which| rig.inject(packets[pieces[which].start..][0..pieces[which].length]);
    try testing.expectEqual(@as(u32, 1), rig.stack.counts.ip_reassembled);
    var buffer: [4096]u8 = undefined;
    try testing.expectEqual(@as(i32, 3000), sb.Recv(socket, &buffer, buffer.len, 0));
    for (buffer[0..3000], 0..) |byte, index| try testing.expectEqual(@as(u8, @truncate(index * 7)), byte);
    kexec.SysBase.iface().CloseLibrary(sb.lib());
    try rig.deinit();
}

test "overlapping fragments, too many, and ones that never finish are given up" {
    var rig = try Rig.init();
    const sb = try rig.open();
    _ = try udpSocket(sb, 7400);
    var packets: [8192]u8 = undefined;
    var pieces: [8]Piece = undefined;
    _ = fragments(&packets, &pieces, 3000, 1200, 2);
    rig.inject(packets[pieces[0].start..][0..pieces[0].length]);
    rig.inject(packets[pieces[0].start..][0..pieces[0].length]);
    try testing.expectEqual(@as(u32, 1), rig.stack.counts.ip_reassembly_dropped);

    // A piece that would end past 65535 bytes.
    var far: [40]u8 = @splat(0);
    ipHeader(&far, @intCast(bsd.IPPROTO_UDP), 3, _ip.flag_more | 8190, 16);
    rig.inject(&far);
    try testing.expectEqual(@as(u32, 2), rig.stack.counts.ip_reassembly_dropped);

    // Five datagrams at once: the fifth finds no room.
    for (0..reassembly.slots_max + 1) |index| {
        _ = fragments(&packets, &pieces, 3000, 1200, @intCast(10 + index));
        rig.inject(packets[pieces[0].start..][0..pieces[0].length]);
    }
    try testing.expectEqual(@as(u32, 3), rig.stack.counts.ip_reassembly_dropped);
    // Their time runs out.
    _timer.run(rig.stack, reassembly.timeout_us);
    try testing.expectEqual(@as(u32, 3 + reassembly.slots_max), rig.stack.counts.ip_reassembly_dropped);
    try testing.expectEqual(@as(u32, 0), rig.stack.frames.used());
    kexec.SysBase.iface().CloseLibrary(sb.lib());
    try rig.deinit();
}

// --- hostile packets ---------------------------------------------------------------------

test "packets that lie about their lengths are dropped, and nothing is read past them" {
    var rig = try Rig.init();
    const sb = try rig.open();
    _ = try udpSocket(sb, 7500);
    const counts = &rig.stack.counts;
    var packet: [64]u8 = @splat(0);

    // A header length past the packet.
    ipHeader(&packet, @intCast(bsd.IPPROTO_UDP), 1, 0, 8);
    packet[0] = 0x4F;
    rig.inject(packet[0..28]);
    // A total length shorter than the header, and longer than the packet.
    ipHeader(&packet, @intCast(bsd.IPPROTO_UDP), 2, 0, 8);
    _ip.put16(&packet, 2, 12);
    rig.inject(packet[0..28]);
    ipHeader(&packet, @intCast(bsd.IPPROTO_UDP), 3, 0, 8);
    _ip.put16(&packet, 2, 600);
    rig.inject(packet[0..28]);
    // Not version 4, and shorter than any header.
    ipHeader(&packet, @intCast(bsd.IPPROTO_UDP), 4, 0, 8);
    packet[0] = 0x65;
    rig.inject(packet[0..28]);
    rig.inject(packet[0..10]);
    try testing.expectEqual(@as(u32, 5), counts.ip_bad_header);
    // A header whose checksum is wrong.
    ipHeader(&packet, @intCast(bsd.IPPROTO_UDP), 5, 0, 8);
    packet[10] ^= 0xFF;
    rig.inject(packet[0..28]);
    try testing.expectEqual(@as(u32, 1), counts.ip_bad_checksum);

    // A UDP length past the datagram, and shorter than its header.
    ipHeader(&packet, @intCast(bsd.IPPROTO_UDP), 6, 0, 8);
    _ip.put16(&packet, 20, 5555);
    _ip.put16(&packet, 22, 7500);
    _ip.put16(&packet, 24, 40);
    rig.inject(packet[0..28]);
    _ip.put16(&packet, 24, 4);
    rig.inject(packet[0..28]);
    try testing.expectEqual(@as(u32, 2), counts.udp_bad);

    // An ICMP error that quotes a header cut short.
    ipHeader(&packet, @intCast(bsd.IPPROTO_ICMP), 7, 0, 20);
    @memset(packet[20..40], 0);
    packet[20] = _icmp.destination_unreachable;
    packet[21] = _icmp.code_port;
    packet[28] = 0x4F;
    _ip.put16(&packet, 22, _ip.finish(_ip.sum(0, packet[20..40])));
    rig.inject(packet[0..40]);
    try testing.expectEqual(@as(u32, 1), counts.icmp_received);

    // ARP with the wrong address lengths.
    const frame = rig.stack.frames.take(rig.stack.sys_base).?;
    const arp = frame.room()[frame.start..][0.._arp.packet_bytes];
    @memset(arp, 0);
    _ip.put16(arp, 0, 1);
    _ip.put16(arp, 2, _ip.ethertype);
    arp[4] = 8;
    arp[5] = 4;
    frame.length = _arp.packet_bytes;
    _arp.input(rig.stack, _netif.loopbackOf(rig.stack), frame, 0);
    try testing.expectEqual(@as(u32, 1), rig.stack.arp.bad);

    try testing.expectEqual(@as(u32, 0), rig.stack.frames.used());
    kexec.SysBase.iface().CloseLibrary(sb.lib());
    try rig.deinit();
}
