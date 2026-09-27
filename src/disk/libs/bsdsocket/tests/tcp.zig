// SPDX-License-Identifier: MIT
//! Host tests of TCP: two stacks in one process, A at 10.0.0.1 and B at
//! 10.0.0.2, joined by a link that is the test's own. What one stack
//! sends waits on the wire until the test pumps it across, so the test
//! decides the order of everything and sees every segment. Time is the
//! test's too: the stacks run without a task, and the test runs their
//! timers.
//!
//! Every socket is one that does not wait, since nothing else runs while
//! a test would wait.

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
const _timer = @import("../timer/_timer.zig");
const _tcp = @import("../tcp/_tcp.zig");
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;

const testing = std.testing;

var lent: [1024 * 1024]u8 align(16) = undefined;

const address_a: u32 = 0x0A00_0001;
const address_b: u32 = 0x0A00_0002;
/// The Ethernet address on both ends of the link, which has no ARP.
const station: [6]u8 = .{ 2, 0, 0, 0, 0, 1 };

// --- the wire -----------------------------------------------------------------------

const Packet = struct {
    to_b: bool,
    length: usize,
    bytes: [1600]u8,
};

var wire: [128]Packet = undefined;
var wire_count: usize = 0;
var segments_seen: usize = 0;

fn onto(to_b: bool, stack: *StackBase, frame: *Frame) i32 {
    const bytes = frame.bytes();
    wire[wire_count] = .{ .to_b = to_b, .length = bytes.len, .bytes = undefined };
    @memcpy(wire[wire_count].bytes[0..bytes.len], bytes);
    wire_count += 1;
    segments_seen += 1;
    stack.frames.give(stack.sys_base, frame);
    return 0;
}

fn fromA(stack: *StackBase, _: *Interface, frame: *Frame, _: *const [6]u8, _: u16) i32 {
    return onto(true, stack, frame);
}

fn fromB(stack: *StackBase, _: *Interface, frame: *Frame, _: *const [6]u8, _: u16) i32 {
    return onto(false, stack, frame);
}

const Side = struct {
    lib: *exec.Library,
    stack: *StackBase,
    interface: *Interface,
    sb: *SocketBase,
};

const Rig = struct {
    kub: *utility_library.UtilityBase,
    region: *exec.MemHeader,
    a: Side,
    b: Side,

    fn init() !Rig {
        const kub = try utility_library.setUp();
        const sys = kexec.SysBase.iface();
        const region = sys.AddMemList(lent.len, exec.MEMF_ANY, 0, &lent, "lent").?;
        wire_count = 0;
        segments_seen = 0;
        return .{
            .kub = kub,
            .region = region,
            .a = try side(address_a, &fromA),
            .b = try side(address_b, &fromB),
        };
    }

    /// A stack made as the library's init makes it, but on no list, with
    /// its interface on the wire.
    fn side(address: u32, transmit: _netif.TransmitFn) !Side {
        const sys = kexec.SysBase.iface();
        const table: *const exec.InitTable = @ptrCast(@alignCast(bsdsocket.bsdsocket_library_tag.init.?));
        const lib = sys.MakeLibrary(table.vectors, table.vector_count, table.data_size, table.init, null) orelse return error.NoStack;
        const stack = _base.stackBase(lib);
        stack.no_task = 1;
        const interface = _netif.free(stack).?;
        interface.* = .{
            .address = address,
            .netmask = 0xFFFF_FF00,
            .broadcast = address | 0xFF,
            .mtu = 1500,
            .used = 1,
            .up = 1,
            .no_arp = 1,
            .transmit = transmit,
        };
        _ = _route.add(stack, address, 0xFFFF_FF00, 0, interface);
        const opened = lib.vector(exec.OpenFn, exec.LIB_OPEN)(lib, 1) orelse return error.NoBase;
        return .{ .lib = lib, .stack = stack, .interface = interface, .sb = @ptrCast(opened) };
    }

    /// Everything on the wire delivered, and what that sends in turn,
    /// until the wire is quiet.
    fn pump(rig: *Rig) void {
        var rounds: usize = 0;
        while (wire_count > 0 and rounds < 1000) : (rounds += 1) {
            const packet = wire[0];
            std.mem.copyForwards(Packet, wire[0 .. wire_count - 1], wire[1..wire_count]);
            wire_count -= 1;
            const target = if (packet.to_b) &rig.b else &rig.a;
            const frame = target.stack.frames.take(target.stack.sys_base).?;
            @memcpy(frame.room()[frame.start..][0..packet.length], packet.bytes[0..packet.length]);
            frame.length = @intCast(packet.length);
            _netif.receive(target.stack, target.interface, frame, &station, &station, _ip.ethertype, target.stack.fixed_time);
        }
    }

    /// Only the first packet on the wire delivered.
    fn pumpOne(rig: *Rig) void {
        const packet = wire[0];
        std.mem.copyForwards(Packet, wire[0 .. wire_count - 1], wire[1..wire_count]);
        wire_count -= 1;
        rig.deliver(&packet);
    }

    /// Both stacks' clocks set to `now`, and their timers run.
    fn advance(rig: *Rig, now: u64) void {
        rig.a.stack.fixed_time = now;
        rig.b.stack.fixed_time = now;
        _timer.run(rig.a.stack, now);
        _timer.run(rig.b.stack, now);
    }

    /// The earliest deadline of either stack.
    fn earliest(rig: *Rig) ?u64 {
        const a = _timer.earliest(rig.a.stack);
        const b = _timer.earliest(rig.b.stack);
        if (a == null) return b;
        if (b == null) return a;
        return @min(a.?, b.?);
    }

    /// One pass over what is on the wire now: each packet dropped,
    /// delivered, delivered twice, or held back behind the next, as the
    /// link's odds say. What the deliveries send waits for the next pass.
    fn pumpLossy(rig: *Rig, link: *Lossy) void {
        var batch: [128]Packet = undefined;
        const count = wire_count;
        @memcpy(batch[0..count], wire[0..count]);
        wire_count = 0;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            if (link.chance(link.reorder) and index + 1 < count) {
                const held = batch[index];
                batch[index] = batch[index + 1];
                batch[index + 1] = held;
            }
            const packet = batch[index];
            if (link.chance(link.loss)) {
                link.dropped += 1;
                continue;
            }
            rig.deliver(&packet);
            if (link.chance(link.duplicate)) rig.deliver(&packet);
        }
    }

    fn deliver(rig: *Rig, packet: *const Packet) void {
        const target = if (packet.to_b) &rig.b else &rig.a;
        const frame = target.stack.frames.take(target.stack.sys_base) orelse return;
        @memcpy(frame.room()[frame.start..][0..packet.length], packet.bytes[0..packet.length]);
        frame.length = @intCast(packet.length);
        _netif.receive(target.stack, target.interface, frame, &station, &station, _ip.ethertype, target.stack.fixed_time);
    }

    fn deinit(rig: *Rig) !void {
        const sys = kexec.SysBase.iface();
        for ([_]*Side{ &rig.a, &rig.b }) |each| {
            sys.CloseLibrary(each.sb.lib());
            try testing.expectEqual(@as(u32, 0), each.stack.frames.used());
            try testing.expectEqual(@as(u16, 0), each.lib.open_cnt);
            _ = each.lib.vector(exec.ExpungeFn, exec.LIB_EXPUNGE)(each.lib);
        }
        try testing.expectEqual(@intFromPtr(rig.region.upper) - @intFromPtr(rig.region.lower), rig.region.free);
        sys.Remove(&rig.region.node);
        try utility_library.tearDown(rig.kub);
        kexec.deinit();
    }
};

/// The socket behind a descriptor of a side's opener.
fn socketOf(side: *Side, descriptor: i32) *@import("../socket/_socket.zig").Socket {
    const opener = _base.socketBase(side.sb.lib());
    return opener.table.?[@intCast(descriptor)].?;
}

/// A link's odds, in percent, and the generator that rolls them: the
/// same seed gives the same losses every run.
const Lossy = struct {
    loss: u32 = 0,
    duplicate: u32 = 0,
    reorder: u32 = 0,
    state: u32 = 0x1234_5678,
    dropped: u32 = 0,

    fn chance(link: *Lossy, percent: u32) bool {
        link.state = link.state *% 1_103_515_245 +% 12345;
        return (link.state >> 16) % 100 < percent;
    }
};

fn stream(sb: *SocketBase) !i32 {
    const socket = sb.Socket(bsd.PF_INET, bsd.SOCK_STREAM, 0);
    if (socket < 0) return error.NoSocket;
    var never: i32 = 1;
    _ = sb.IoctlSocket(socket, bsd.FIONBIO, &never);
    return socket;
}

fn at(address: u32, port: u16) bsd.sockaddr_in {
    return .{ .sin_port = bsd.htons(port), .sin_addr = .{ .s_addr = bsd.htonl(address) } };
}

/// B listening on `port`, A connected to it, B's end accepted.
fn connected(rig: *Rig, port: u16) !struct { client: i32, server: i32, listener: i32 } {
    const listener = try stream(rig.b.sb);
    var here = at(address_b, port);
    try testing.expectEqual(@as(i32, 0), rig.b.sb.Bind(listener, here.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(@as(i32, 0), rig.b.sb.Listen(listener, 4));
    const client = try stream(rig.a.sb);
    try testing.expectEqual(@as(i32, -1), rig.a.sb.Connect(client, here.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(bsd.EINPROGRESS, rig.a.sb.Errno());
    rig.pump();
    var peer: bsd.sockaddr_in = .{};
    var peer_length: u32 = @sizeOf(bsd.sockaddr_in);
    const server = rig.b.sb.Accept(listener, peer.any(), &peer_length);
    try testing.expect(server >= 0);
    try testing.expectEqual(bsd.htonl(address_a), peer.sin_addr.s_addr);
    return .{ .client = client, .server = server, .listener = listener };
}

test "a connection opens, carries data both ways, and closes from either side" {
    var rig = try Rig.init();
    const pair = try connected(&rig, 80);
    const a = rig.a.sb;
    const b = rig.b.sb;
    // Connected: writable, and the handshake was three segments.
    var write: bsd.fd_set = .{};
    write.set(pair.client);
    var now: bsd.timeval = .{};
    try testing.expectEqual(@as(i32, 1), a.WaitSelect(pair.client + 1, null, &write, null, &now, null));
    try testing.expectEqual(@as(usize, 3), segments_seen);

    try testing.expectEqual(@as(i32, 5), a.Send(pair.client, "hello", 5, 0));
    rig.pump();
    var buffer: [64]u8 = undefined;
    try testing.expectEqual(@as(i32, 5), b.Recv(pair.server, &buffer, buffer.len, 0));
    try testing.expectEqualStrings("hello", buffer[0..5]);
    try testing.expectEqual(@as(i32, 5), b.Send(pair.server, "world", 5, 0));
    rig.pump();
    try testing.expectEqual(@as(i32, 5), a.Recv(pair.client, &buffer, buffer.len, 0));
    try testing.expectEqualStrings("world", buffer[0..5]);
    // Nothing more yet.
    try testing.expectEqual(@as(i32, -1), a.Recv(pair.client, &buffer, buffer.len, 0));
    try testing.expectEqual(bsd.EWOULDBLOCK, a.Errno());

    // A closes: B reads to the end of the stream, then closes too.
    try testing.expectEqual(@as(i32, 0), a.CloseSocket(pair.client));
    rig.pump();
    try testing.expectEqual(@as(i32, 0), b.Recv(pair.server, &buffer, buffer.len, 0));
    try testing.expectEqual(@as(i32, 0), b.CloseSocket(pair.server));
    rig.pump();
    // A's end waits out TIME_WAIT as an orphan, holding its stack.
    try testing.expectEqual(@as(u16, 2), rig.a.lib.open_cnt);
    rig.advance(2 * _tcp.msl_us);
    try testing.expectEqual(@as(u16, 1), rig.a.lib.open_cnt);
    _ = b.CloseSocket(pair.listener);
    try rig.deinit();
}

test "GetNetworkStatistics tells of the sockets, the routes and the counters" {
    var rig = try Rig.init();
    const pair = try connected(&rig, 80);
    const b = rig.b.sb;
    try testing.expectEqual(@as(i32, 5), rig.a.sb.Send(pair.client, "hello", 5, 0));
    rig.pump();

    // Asked with no room: how many there are.
    try testing.expectEqual(@as(i32, 2), b.GetNetworkStatistics(bsd.NETSTATUS_SOCKETS, null, 0));
    var sockets: [4]bsd.SocketInfo = undefined;
    try testing.expectEqual(@as(i32, 2), b.GetNetworkStatistics(bsd.NETSTATUS_SOCKETS, &sockets, @sizeOf(@TypeOf(sockets))));
    var listening: ?bsd.SocketInfo = null;
    var established: ?bsd.SocketInfo = null;
    for (sockets[0..2]) |info| {
        if (info.tcp_state == bsd.TCPS_LISTEN) listening = info;
        if (info.tcp_state == bsd.TCPS_ESTABLISHED) established = info;
    }
    try testing.expectEqual(pair.listener, listening.?.descriptor);
    try testing.expectEqual(@as(u16, 80), listening.?.local_port);
    try testing.expectEqual(pair.server, established.?.descriptor);
    // IPv4 as IPv6 has it: mapped.
    try testing.expectEqual(bsd.htonl(address_a), @as(*align(1) const u32, @ptrCast(established.?.remote_address.s6_addr[12..16])).*);
    try testing.expectEqual(@as(u8, 0xff), established.?.remote_address.s6_addr[11]);
    try testing.expectEqual(@as(u32, 5), established.?.receive_queued);
    try testing.expectEqual(@as(u8, 0), established.?.flags);
    // Room for one: one written, both counted.
    try testing.expectEqual(@as(i32, 2), b.GetNetworkStatistics(bsd.NETSTATUS_SOCKETS, &sockets, @sizeOf(bsd.SocketInfo) + 3));

    var routes: [4]bsd.RouteInfo = undefined;
    const route_count = b.GetNetworkStatistics(bsd.NETSTATUS_ROUTES, &routes, @sizeOf(@TypeOf(routes)));
    try testing.expectEqual(@as(i32, 2), route_count);
    try testing.expectEqualStrings("lo0", std.mem.sliceTo(&routes[0].interface, 0));
    try testing.expectEqual(bsd.htonl(address_b & 0xFFFF_FF00), routes[1].destination);
    try testing.expectEqual(@as(u32, 0), routes[1].gateway);

    var counts: bsd.NetCounts = .{};
    try testing.expectEqual(@as(i32, 1), b.GetNetworkStatistics(bsd.NETSTATUS_COUNTS, &counts, @sizeOf(bsd.NetCounts)));
    try testing.expect(counts.tcp_received >= 3);
    try testing.expectEqual(counts.tcp_received, counts.ip_received);
    try testing.expectEqual(@as(i32, 0), b.GetNetworkStatistics(bsd.NETSTATUS_ARP, null, 0));
    try testing.expectEqual(@as(i32, -1), b.GetNetworkStatistics(99, null, 0));
    try testing.expectEqual(bsd.EINVAL, b.Errno());

    closeAll(&rig, pair);
    try rig.deinit();
}

test "a connection to a port nobody listens on is refused" {
    var rig = try Rig.init();
    const a = rig.a.sb;
    const client = try stream(a);
    var nobody = at(address_b, 81);
    _ = a.Connect(client, nobody.anyConst(), @sizeOf(bsd.sockaddr_in));
    rig.pump();
    try testing.expectEqual(@as(u32, 1), rig.b.stack.counts.tcp_resets_sent);
    var write: bsd.fd_set = .{};
    write.set(client);
    var now: bsd.timeval = .{};
    try testing.expectEqual(@as(i32, 1), a.WaitSelect(client + 1, null, &write, null, &now, null));
    var pending: i32 = 0;
    var size: u32 = @sizeOf(i32);
    try testing.expectEqual(@as(i32, 0), a.GetSockOpt(client, bsd.SOL_SOCKET, bsd.SO_ERROR, &pending, &size));
    try testing.expectEqual(bsd.ECONNREFUSED, pending);
    _ = a.CloseSocket(client);
    try rig.deinit();
}

test "a full receive ring shuts the window, and reading opens it again" {
    var rig = try Rig.init();
    const pair = try connected(&rig, 82);
    const a = rig.a.sb;
    const b = rig.b.sb;
    const small: i32 = 1024;
    try testing.expectEqual(@as(i32, 0), b.SetSockOpt(pair.server, bsd.SOL_SOCKET, bsd.SO_RCVBUF, &small, @sizeOf(i32)));
    // The window B offered at first was the old ring's; a segment tells A
    // the new one.
    _ = b.Send(pair.server, "x", 1, 0);
    rig.pump();
    var drain: [8]u8 = undefined;
    _ = a.Recv(pair.client, &drain, drain.len, 0);

    var data: [3000]u8 = undefined;
    for (&data, 0..) |*byte, index| byte.* = @truncate(index);
    try testing.expectEqual(@as(i32, 3000), a.Send(pair.client, &data, data.len, 0));
    rig.pump();
    var got: [3000]u8 = undefined;
    var received: usize = 0;
    var rounds: usize = 0;
    while (received < data.len and rounds < 20) : (rounds += 1) {
        const taken = b.Recv(pair.server, got[received..].ptr, @intCast(got.len - received), 0);
        if (taken > 0) received += @intCast(taken);
        rig.pump();
    }
    try testing.expectEqual(data.len, received);
    try testing.expectEqualSlices(u8, &data, &got);
    _ = a.CloseSocket(pair.client);
    _ = b.CloseSocket(pair.server);
    rig.pump();
    rig.advance(2 * _tcp.msl_us);
    _ = b.CloseSocket(pair.listener);
    try rig.deinit();
}

test "both ends closing at once go through CLOSING to TIME_WAIT" {
    var rig = try Rig.init();
    const pair = try connected(&rig, 83);
    const a = rig.a.sb;
    const b = rig.b.sb;
    try testing.expectEqual(@as(i32, 0), a.Shutdown(pair.client, bsd.SHUT_WR));
    try testing.expectEqual(@as(i32, 0), b.Shutdown(pair.server, bsd.SHUT_WR));
    rig.pump();
    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(i32, 0), a.Recv(pair.client, &buffer, buffer.len, 0));
    try testing.expectEqual(@as(i32, 0), b.Recv(pair.server, &buffer, buffer.len, 0));
    const a_tcb = _tcp.of(socketOf(&rig.a, pair.client));
    try testing.expectEqual(_tcp.State.time_wait, a_tcb.state);
    try testing.expectEqual(@as(i32, -1), a.Send(pair.client, "x", 1, 0));
    try testing.expectEqual(bsd.EPIPE, a.Errno());
    _ = a.CloseSocket(pair.client);
    _ = b.CloseSocket(pair.server);
    rig.advance(2 * _tcp.msl_us);
    _ = b.CloseSocket(pair.listener);
    try rig.deinit();
}

test "a listener's queue holds what it was told, and a reset reaches the program" {
    var rig = try Rig.init();
    const b = rig.b.sb;
    const a = rig.a.sb;
    const listener = try stream(b);
    var here = at(address_b, 84);
    _ = b.Bind(listener, here.anyConst(), @sizeOf(bsd.sockaddr_in));
    _ = b.Listen(listener, 1);
    const first = try stream(a);
    const second = try stream(a);
    _ = a.Connect(first, here.anyConst(), @sizeOf(bsd.sockaddr_in));
    _ = a.Connect(second, here.anyConst(), @sizeOf(bsd.sockaddr_in));
    rig.pump();
    try testing.expectEqual(@as(u32, 1), rig.b.stack.counts.tcp_backlog_full);
    const server = b.Accept(listener, null, null);
    try testing.expect(server >= 0);
    try testing.expectEqual(@as(i32, -1), b.Accept(listener, null, null));
    try testing.expectEqual(bsd.EWOULDBLOCK, b.Errno());

    // SO_LINGER with no time resets: A hears ECONNRESET.
    const cut: bsd.linger = .{ .l_onoff = 1, .l_linger = 0 };
    _ = b.SetSockOpt(server, bsd.SOL_SOCKET, bsd.SO_LINGER, &cut, @sizeOf(bsd.linger));
    _ = b.CloseSocket(server);
    rig.pump();
    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(i32, -1), a.Recv(first, &buffer, buffer.len, 0));
    try testing.expectEqual(bsd.ECONNRESET, a.Errno());
    _ = a.CloseSocket(first);
    _ = a.CloseSocket(second);
    _ = b.CloseSocket(listener);
    rig.pump();
    try rig.deinit();
}

test "a connection over lo0 to the stack itself" {
    var rig = try Rig.init();
    const a = rig.a.sb;
    const listener = try stream(a);
    var here = at(bsd.INADDR_LOOPBACK, 85);
    _ = a.Bind(listener, here.anyConst(), @sizeOf(bsd.sockaddr_in));
    _ = a.Listen(listener, 2);
    const client = try stream(a);
    _ = a.Connect(client, here.anyConst(), @sizeOf(bsd.sockaddr_in));
    const server = a.Accept(listener, null, null);
    try testing.expect(server >= 0);
    var data: [6000]u8 = undefined;
    for (&data, 0..) |*byte, index| byte.* = @truncate(index * 3);
    try testing.expectEqual(@as(i32, 6000), a.Send(client, &data, data.len, 0));
    var got: [6000]u8 = undefined;
    try testing.expectEqual(@as(i32, 6000), a.Recv(server, &got, got.len, 0));
    try testing.expectEqualSlices(u8, &data, &got);
    _ = a.CloseSocket(client);
    _ = a.CloseSocket(server);
    rig.advance(2 * _tcp.msl_us);
    _ = a.CloseSocket(listener);
    try testing.expectEqual(@as(usize, 0), wire_count);
    try rig.deinit();
}

test "urgent data is set aside at its mark, read with MSG_OOB, and makes the socket exceptional" {
    var rig = try Rig.init();
    const a = rig.a.sb;
    const listener = try stream(a);
    var here = at(bsd.INADDR_LOOPBACK, 86);
    _ = a.Bind(listener, here.anyConst(), @sizeOf(bsd.sockaddr_in));
    _ = a.Listen(listener, 2);
    const client = try stream(a);
    _ = a.Connect(client, here.anyConst(), @sizeOf(bsd.sockaddr_in));
    const server = a.Accept(listener, null, null);
    try testing.expect(server >= 0);

    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(i32, -1), a.Recv(server, &byte, 1, bsd.MSG_OOB));
    try testing.expectEqual(bsd.EINVAL, a.Errno());

    try testing.expectEqual(@as(i32, 2), a.Send(client, "ab", 2, 0));
    try testing.expectEqual(@as(i32, 1), a.Send(client, "X", 1, bsd.MSG_OOB));
    try testing.expectEqual(@as(i32, 2), a.Send(client, "cd", 2, 0));

    var except: bsd.fd_set = .{};
    except.set(server);
    var now: bsd.timeval = .{};
    try testing.expectEqual(@as(i32, 1), a.WaitSelect(server + 1, null, null, &except, &now, null));
    try testing.expect(except.isSet(server));

    var mark: i32 = -1;
    _ = a.IoctlSocket(server, bsd.SIOCATMARK, &mark);
    try testing.expectEqual(@as(i32, 0), mark);
    var got: [8]u8 = undefined;
    try testing.expectEqual(@as(i32, 2), a.Recv(server, &got, got.len, 0));
    try testing.expectEqualSlices(u8, "ab", got[0..2]);
    _ = a.IoctlSocket(server, bsd.SIOCATMARK, &mark);
    try testing.expectEqual(@as(i32, 1), mark);

    try testing.expectEqual(@as(i32, 1), a.Recv(server, &byte, 1, bsd.MSG_OOB | bsd.MSG_PEEK));
    try testing.expectEqual(@as(i32, 1), a.Recv(server, &byte, 1, bsd.MSG_OOB));
    try testing.expectEqual(@as(u8, 'X'), byte[0]);
    try testing.expectEqual(@as(i32, -1), a.Recv(server, &byte, 1, bsd.MSG_OOB));
    try testing.expectEqual(bsd.EINVAL, a.Errno());
    except.set(server);
    try testing.expectEqual(@as(i32, 0), a.WaitSelect(server + 1, null, null, &except, &now, null));

    try testing.expectEqual(@as(i32, 2), a.Recv(server, &got, got.len, 0));
    try testing.expectEqualSlices(u8, "cd", got[0..2]);
    _ = a.IoctlSocket(server, bsd.SIOCATMARK, &mark);
    try testing.expectEqual(@as(i32, 0), mark);

    const datagram = a.Socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    try testing.expectEqual(@as(i32, -1), a.Send(datagram, "X", 1, bsd.MSG_OOB));
    try testing.expectEqual(bsd.EOPNOTSUPP, a.Errno());
    try testing.expectEqual(@as(i32, -1), a.Recv(datagram, &byte, 1, bsd.MSG_OOB));
    try testing.expectEqual(bsd.EOPNOTSUPP, a.Errno());
    _ = a.CloseSocket(datagram);

    _ = a.CloseSocket(client);
    _ = a.CloseSocket(server);
    rig.advance(2 * _tcp.msl_us);
    _ = a.CloseSocket(listener);
    try rig.deinit();
}

test "a stream socket that never connected is not readable, and a receive says ENOTCONN" {
    var rig = try Rig.init();
    const a = rig.a.sb;
    const fresh = try stream(a);
    var read: bsd.fd_set = .{};
    read.set(fresh);
    var now: bsd.timeval = .{};
    try testing.expectEqual(@as(i32, 0), a.WaitSelect(fresh + 1, &read, null, null, &now, null));
    var got: [4]u8 = undefined;
    try testing.expectEqual(@as(i32, -1), a.Recv(fresh, &got, got.len, 0));
    try testing.expectEqual(bsd.ENOTCONN, a.Errno());
    var here = at(bsd.INADDR_LOOPBACK, 87);
    _ = a.Bind(fresh, here.anyConst(), @sizeOf(bsd.sockaddr_in));
    _ = a.Listen(fresh, 1);
    try testing.expectEqual(@as(i32, -1), a.Recv(fresh, &got, got.len, 0));
    try testing.expectEqual(bsd.ENOTCONN, a.Errno());
    _ = a.CloseSocket(fresh);
    try rig.deinit();
}

// --- a link that loses --------------------------------------------------------------

/// Sends `data` from A to B over a link with `link`'s odds, reading at B
/// as it comes and moving time on whenever the wire is quiet, until B has
/// it all or `limit` of simulated time has passed: what B got.
fn transfer(rig: *Rig, pair: anytype, data: []const u8, got: []u8, link: *Lossy, limit: u64) usize {
    var now: u64 = rig.a.stack.fixed_time;
    var sent: usize = 0;
    var received: usize = 0;
    while (received < data.len and now < limit) {
        if (sent < data.len) {
            const taken = rig.a.sb.Send(pair.client, data[sent..].ptr, @intCast(data.len - sent), 0);
            if (taken > 0) sent += @intCast(taken);
        }
        rig.pumpLossy(link);
        while (true) {
            const taken = rig.b.sb.Recv(pair.server, got[received..].ptr, @intCast(got.len - received), 0);
            if (taken <= 0) break;
            received += @intCast(taken);
        }
        // A millisecond per round trip; when nothing is on its way, on to
        // the next deadline.
        now += 1000;
        if (wire_count == 0) {
            if (rig.earliest()) |deadline| now = @max(now, deadline);
        }
        rig.advance(now);
    }
    return received;
}

test "a transfer arrives whole and in order over a link that loses, doubles and reorders" {
    var rig = try Rig.init();
    const pair = try connected(&rig, 90);
    const data = try testing.allocator.alloc(u8, 256 * 1024);
    defer testing.allocator.free(data);
    const got = try testing.allocator.alloc(u8, data.len);
    defer testing.allocator.free(got);
    for (data, 0..) |*byte, index| byte.* = @truncate(index *% 7 +% index / 256);
    var link: Lossy = .{ .loss = 10, .duplicate = 2, .reorder = 5 };
    const received = transfer(&rig, pair, data, got, &link, 600_000_000);
    try testing.expectEqual(data.len, received);
    try testing.expectEqualSlices(u8, data, got);
    try testing.expect(link.dropped > 0);
    const counts = rig.a.stack.counts;
    try testing.expect(counts.tcp_retransmits + counts.tcp_fast_retransmits > 0);
    closeAll(&rig, pair);
    try rig.deinit();
}

test "a dead link backs the timeout off and ends in ETIMEDOUT" {
    var rig = try Rig.init();
    const pair = try connected(&rig, 91);
    _ = rig.a.sb.Send(pair.client, "lost", 4, 0);
    wire_count = 0;
    const tcb = _tcp.of(socketOf(&rig.a, pair.client));
    var last_rto: u32 = 0;
    var rounds: usize = 0;
    while (tcb.state != .closed and rounds < 40) : (rounds += 1) {
        try testing.expect(tcb.rto >= last_rto);
        last_rto = tcb.rto;
        rig.advance(rig.earliest() orelse break);
        wire_count = 0;
    }
    try testing.expectEqual(_tcp.State.closed, tcb.state);
    try testing.expectEqual(@as(u32, 60_000_000), last_rto);
    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(i32, -1), rig.a.sb.Recv(pair.client, &buffer, buffer.len, 0));
    try testing.expectEqual(bsd.ETIMEDOUT, rig.a.sb.Errno());
    // B's end: the peer is gone; it is reset when it next speaks.
    _ = rig.a.sb.CloseSocket(pair.client);
    const cut: bsd.linger = .{ .l_onoff = 1, .l_linger = 0 };
    _ = rig.b.sb.SetSockOpt(pair.server, bsd.SOL_SOCKET, bsd.SO_LINGER, &cut, @sizeOf(bsd.linger));
    _ = rig.b.sb.CloseSocket(pair.server);
    _ = rig.b.sb.CloseSocket(pair.listener);
    wire_count = 0;
    try rig.deinit();
}

test "a lost SYN is sent again, and the connection stands" {
    var rig = try Rig.init();
    const listener = try stream(rig.b.sb);
    var here = at(address_b, 92);
    _ = rig.b.sb.Bind(listener, here.anyConst(), @sizeOf(bsd.sockaddr_in));
    _ = rig.b.sb.Listen(listener, 2);
    const client = try stream(rig.a.sb);
    _ = rig.a.sb.Connect(client, here.anyConst(), @sizeOf(bsd.sockaddr_in));
    try testing.expectEqual(@as(usize, 1), wire_count);
    wire_count = 0;
    rig.advance(rig.earliest().?);
    rig.pump();
    try testing.expectEqual(_tcp.State.established, _tcp.of(socketOf(&rig.a, client)).state);
    const server = rig.b.sb.Accept(listener, null, null);
    try testing.expect(server >= 0);
    closeAll(&rig, .{ .client = client, .server = server, .listener = listener });
    try rig.deinit();
}

test "a shut window is probed, and a lost window update does not stall it" {
    var rig = try Rig.init();
    const pair = try connected(&rig, 93);
    const small: i32 = 1024;
    _ = rig.b.sb.SetSockOpt(pair.server, bsd.SOL_SOCKET, bsd.SO_RCVBUF, &small, @sizeOf(i32));
    _ = rig.b.sb.Send(pair.server, "w", 1, 0);
    rig.pump();
    var one: [1]u8 = undefined;
    _ = rig.a.sb.Recv(pair.client, &one, 1, 0);
    var data: [4096]u8 = undefined;
    for (&data, 0..) |*byte, index| byte.* = @truncate(index * 5);
    _ = rig.a.sb.Send(pair.client, &data, data.len, 0);
    rig.pump();
    // B's delayed acknowledgement says the window is shut.
    rig.advance(rig.b.stack.fixed_time + 200_000);
    rig.pump();
    try testing.expectEqual(@as(u32, 0), _tcp.of(socketOf(&rig.a, pair.client)).snd_wnd);
    // B's ring is full; B reads it all, and the window update is lost.
    var got: [4096]u8 = undefined;
    var received: usize = @intCast(rig.b.sb.Recv(pair.server, &got, got.len, 0));
    wire_count = 0;
    var rounds: usize = 0;
    while (received < data.len and rounds < 50) : (rounds += 1) {
        rig.advance(rig.earliest() orelse break);
        rig.pump();
        const taken = rig.b.sb.Recv(pair.server, got[received..].ptr, @intCast(got.len - received), 0);
        if (taken > 0) received += @intCast(taken);
        rig.pump();
    }
    try testing.expectEqual(data.len, received);
    try testing.expectEqualSlices(u8, &data, &got);
    try testing.expect(rig.a.stack.counts.tcp_window_probes > 0);
    closeAll(&rig, pair);
    try rig.deinit();
}

test "TIME_WAIT answers a FIN sent again, then goes" {
    var rig = try Rig.init();
    const pair = try connected(&rig, 94);
    _ = rig.a.sb.CloseSocket(pair.client);
    rig.pump();
    _ = rig.b.sb.CloseSocket(pair.server);
    // B's FIN reaches A, and A's last acknowledgement is lost.
    rig.pumpOne();
    try testing.expectEqual(@as(usize, 1), wire_count);
    wire_count = 0;
    const b_counts = &rig.b.stack.counts;
    rig.advance(rig.b.stack.fixed_time + 1_000_000);
    try testing.expect(b_counts.tcp_retransmits > 0);
    rig.pump();
    // B has its acknowledgement and is gone; A waits out TIME_WAIT.
    try testing.expectEqual(@as(u16, 1), rig.b.lib.open_cnt);
    try testing.expectEqual(@as(u16, 2), rig.a.lib.open_cnt);
    rig.advance(rig.a.stack.fixed_time + 2 * _tcp.msl_us);
    try testing.expectEqual(@as(u16, 1), rig.a.lib.open_cnt);
    _ = rig.b.sb.CloseSocket(pair.listener);
    try rig.deinit();
}

/// Both ends closed and the connection let finish, TIME_WAIT included.
fn closeAll(rig: *Rig, pair: anytype) void {
    _ = rig.a.sb.CloseSocket(pair.client);
    _ = rig.b.sb.CloseSocket(pair.server);
    var rounds: usize = 0;
    while (rounds < 100) : (rounds += 1) {
        rig.pump();
        const next = rig.earliest() orelse break;
        rig.advance(next);
    }
    _ = rig.b.sb.CloseSocket(pair.listener);
}

test "keepalive keeps a quiet connection whose peer answers, and ends one whose peer is gone" {
    var rig = try Rig.init();
    const pair = try connected(&rig, 95);
    const on: i32 = 1;
    try testing.expectEqual(@as(i32, 0), rig.a.sb.SetSockOpt(pair.client, bsd.SOL_SOCKET, bsd.SO_KEEPALIVE, &on, @sizeOf(i32)));
    const tcb = _tcp.of(socketOf(&rig.a, pair.client));
    // Two hours of quiet: A asks, B answers, and it goes on.
    rig.advance(rig.earliest().?);
    try testing.expectEqual(@as(usize, 1), wire_count);
    rig.pump();
    try testing.expectEqual(_tcp.State.established, tcb.state);
    // B gone: nine probes unanswered, and the connection ends.
    var rounds: usize = 0;
    while (tcb.state == .established and rounds < 20) : (rounds += 1) {
        rig.advance(rig.earliest().?);
        wire_count = 0;
    }
    try testing.expectEqual(_tcp.State.closed, tcb.state);
    var buffer: [4]u8 = undefined;
    try testing.expectEqual(@as(i32, -1), rig.a.sb.Recv(pair.client, &buffer, buffer.len, 0));
    try testing.expectEqual(bsd.ETIMEDOUT, rig.a.sb.Errno());
    _ = rig.a.sb.CloseSocket(pair.client);
    const cut: bsd.linger = .{ .l_onoff = 1, .l_linger = 0 };
    _ = rig.b.sb.SetSockOpt(pair.server, bsd.SOL_SOCKET, bsd.SO_LINGER, &cut, @sizeOf(bsd.linger));
    _ = rig.b.sb.CloseSocket(pair.server);
    _ = rig.b.sb.CloseSocket(pair.listener);
    wire_count = 0;
    try rig.deinit();
}

// --- hostile segments -------------------------------------------------------------

/// A segment written by the test, as if A's end of `pair` had sent it,
/// handed to B.
const Forged = struct {
    seq: u32,
    ack: u32,
    flags: u8,
    data: []const u8 = &.{},
    /// Options as they are, and a data offset that lies if not null.
    options: []const u8 = &.{},
    offset_words: ?u8 = null,
};

fn forge(rig: *Rig, client_port: u16, server_port: u16, segment: Forged) void {
    var packet: [1600]u8 = @splat(0);
    const tcp_length = 20 + segment.options.len + segment.data.len;
    packet[0] = 0x45;
    _ip.put16(&packet, 2, @intCast(20 + tcp_length));
    packet[8] = 64;
    packet[9] = @intCast(bsd.IPPROTO_TCP);
    _ip.put32(&packet, 12, address_a);
    _ip.put32(&packet, 16, address_b);
    _ip.put16(&packet, 10, _ip.finish(_ip.sum(0, packet[0..20])));
    const tcp = packet[20..][0..tcp_length];
    _ip.put16(tcp, 0, client_port);
    _ip.put16(tcp, 2, server_port);
    _ip.put32(tcp, 4, segment.seq);
    _ip.put32(tcp, 8, segment.ack);
    const words: u8 = segment.offset_words orelse @intCast((20 + segment.options.len) / 4);
    tcp[12] = words << 4;
    tcp[13] = segment.flags;
    _ip.put16(tcp, 14, 8192);
    @memcpy(tcp[20..][0..segment.options.len], segment.options);
    @memcpy(tcp[20 + segment.options.len ..][0..segment.data.len], segment.data);
    _ip.put16(tcp, 16, _ip.finish(_ip.sum(_ip.pseudoSum(address_a, address_b, @intCast(bsd.IPPROTO_TCP), @intCast(tcp_length)), tcp)));
    const frame = rig.b.stack.frames.take(rig.b.stack.sys_base).?;
    @memcpy(frame.room()[frame.start..][0 .. 20 + tcp_length], packet[0 .. 20 + tcp_length]);
    frame.length = @intCast(20 + tcp_length);
    _ip.input(rig.b.stack, rig.b.interface, frame);
}

test "a reset inside the window but not at its edge draws a challenge, and only the exact one resets" {
    var rig = try Rig.init();
    const pair = try connected(&rig, 96);
    const server = _tcp.of(socketOf(&rig.b, pair.server));
    const client_port = socketOf(&rig.a, pair.client).local_port;
    const counts = &rig.b.stack.counts;
    // A flood of guessed resets: a few challenges, then the limit.
    for (0..30) |guess| forge(&rig, client_port, 96, .{ .seq = server.rcv_nxt +% 100 +% @as(u32, @intCast(guess)), .ack = 0, .flags = _tcp.RST });
    try testing.expectEqual(_tcp.State.established, server.state);
    try testing.expectEqual(@as(u32, 10), counts.tcp_challenges);
    try testing.expectEqual(@as(u32, 20), counts.tcp_challenges_dropped);
    // A SYN on a standing connection: a challenge too, and nothing else.
    rig.advance(1_000_000);
    forge(&rig, client_port, 96, .{ .seq = server.rcv_nxt, .ack = 0, .flags = _tcp.SYN });
    try testing.expectEqual(_tcp.State.established, server.state);
    try testing.expectEqual(@as(u32, 11), counts.tcp_challenges);
    // An acknowledgement for what was never sent.
    forge(&rig, client_port, 96, .{ .seq = server.rcv_nxt, .ack = server.snd_max +% 5000, .flags = _tcp.ACK });
    try testing.expectEqual(@as(u32, 12), counts.tcp_challenges);
    // The exact one.
    forge(&rig, client_port, 96, .{ .seq = server.rcv_nxt, .ack = 0, .flags = _tcp.RST });
    var buffer: [4]u8 = undefined;
    try testing.expectEqual(@as(i32, -1), rig.b.sb.Recv(pair.server, &buffer, buffer.len, 0));
    try testing.expectEqual(bsd.ECONNRESET, rig.b.sb.Errno());
    wire_count = 0;
    _ = rig.b.sb.CloseSocket(pair.server);
    _ = rig.b.sb.CloseSocket(pair.listener);
    const cut: bsd.linger = .{ .l_onoff = 1, .l_linger = 0 };
    _ = rig.a.sb.SetSockOpt(pair.client, bsd.SOL_SOCKET, bsd.SO_LINGER, &cut, @sizeOf(bsd.linger));
    _ = rig.a.sb.CloseSocket(pair.client);
    wire_count = 0;
    try rig.deinit();
}

test "segments that lie about their headers, options and places are dropped or trimmed" {
    var rig = try Rig.init();
    const pair = try connected(&rig, 97);
    const server = _tcp.of(socketOf(&rig.b, pair.server));
    const client_port = socketOf(&rig.a, pair.client).local_port;
    const counts = &rig.b.stack.counts;
    const bad_before = counts.tcp_bad;
    // A data offset past the segment, and one below the header.
    forge(&rig, client_port, 97, .{ .seq = server.rcv_nxt, .ack = server.snd_una, .flags = _tcp.ACK, .offset_words = 15 });
    forge(&rig, client_port, 97, .{ .seq = server.rcv_nxt, .ack = server.snd_una, .flags = _tcp.ACK, .offset_words = 2 });
    try testing.expectEqual(bad_before + 2, counts.tcp_bad);
    // Options of length 0, of length 1, and running past their space:
    // the walk stops, and the segment is taken as it is.
    for ([_][4]u8{ .{ 5, 0, 1, 1 }, .{ 5, 1, 1, 1 }, .{ 1, 1, 2, 9 } }) |options| {
        forge(&rig, client_port, 97, .{ .seq = server.rcv_nxt, .ack = server.snd_una, .flags = _tcp.ACK | _tcp.PSH, .options = &options, .data = "o" });
    }
    var buffer: [16]u8 = undefined;
    try testing.expectEqual(@as(i32, 3), rig.b.sb.Recv(pair.server, &buffer, buffer.len, 0));
    // Far outside the window: acknowledged, nothing taken.
    forge(&rig, client_port, 97, .{ .seq = server.rcv_nxt +% 0x4000_0000, .ack = server.snd_una, .flags = _tcp.ACK, .data = "far" });
    try testing.expectEqual(@as(i32, -1), rig.b.sb.Recv(pair.server, &buffer, buffer.len, 0));
    // More than the window: what fits is taken, the rest trimmed.
    const small: i32 = 1024;
    _ = rig.b.sb.SetSockOpt(pair.server, bsd.SOL_SOCKET, bsd.SO_RCVBUF, &small, @sizeOf(i32));
    var big: [1400]u8 = @splat('w');
    forge(&rig, client_port, 97, .{ .seq = server.rcv_nxt, .ack = server.snd_una, .flags = _tcp.ACK, .data = &big });
    try testing.expectEqual(@as(u32, 1024), server.receive.count);
    wire_count = 0;
    try testing.expectEqual(@as(u32, 0), rig.b.stack.frames.used());
    const cut: bsd.linger = .{ .l_onoff = 1, .l_linger = 0 };
    _ = rig.b.sb.SetSockOpt(pair.server, bsd.SOL_SOCKET, bsd.SO_LINGER, &cut, @sizeOf(bsd.linger));
    _ = rig.b.sb.CloseSocket(pair.server);
    _ = rig.b.sb.CloseSocket(pair.listener);
    _ = rig.a.sb.SetSockOpt(pair.client, bsd.SOL_SOCKET, bsd.SO_LINGER, &cut, @sizeOf(bsd.linger));
    _ = rig.a.sb.CloseSocket(pair.client);
    wire_count = 0;
    try rig.deinit();
}

test "SipHash-2-4 gives the reference answers" {
    const isn = @import("../tcp/isn.zig");
    var key: [16]u8 = undefined;
    for (&key, 0..) |*byte, index| byte.* = @intCast(index);
    try testing.expectEqual(@as(u64, 0x726fdb47dd0e0e31), isn.sipHash(&key, &.{}));
    var message: [15]u8 = undefined;
    for (&message, 0..) |*byte, index| byte.* = @intCast(index);
    try testing.expectEqual(@as(u64, 0xa129ca6149be45e5), isn.sipHash(&key, &message));
}

// --- running out of memory -----------------------------------------------------------

var real_alloc: ?*const anyopaque = null;
var allocations: u32 = 0;
var fail_at: u32 = 0;

fn failingAlloc(sys: *sdk.interface.exec.ExecBase, size: usize, requirements: u32) callconv(.c) ?*anyopaque {
    allocations += 1;
    if (allocations == fail_at) return null;
    const real: sdk.interface.exec.Fn.AllocMem = @ptrCast(@alignCast(real_alloc.?));
    return real(sys, size, requirements);
}

/// A whole connection over lo0 on A, given up at the first call that
/// fails, as a program would; then everything closed and let finish.
fn connection(rig: *Rig) void {
    const a = rig.a.sb;
    const listener = a.Socket(bsd.PF_INET, bsd.SOCK_STREAM, 0);
    if (listener < 0) return;
    defer _ = a.CloseSocket(listener);
    var never: i32 = 1;
    _ = a.IoctlSocket(listener, bsd.FIONBIO, &never);
    var here = at(bsd.INADDR_LOOPBACK, 7700);
    if (a.Bind(listener, here.anyConst(), @sizeOf(bsd.sockaddr_in)) < 0) return;
    if (a.Listen(listener, 2) < 0) return;
    const client = a.Socket(bsd.PF_INET, bsd.SOCK_STREAM, 0);
    if (client < 0) return;
    defer _ = a.CloseSocket(client);
    _ = a.IoctlSocket(client, bsd.FIONBIO, &never);
    _ = a.Connect(client, here.anyConst(), @sizeOf(bsd.sockaddr_in));
    const server = a.Accept(listener, null, null);
    if (server < 0) return;
    defer _ = a.CloseSocket(server);
    if (a.Send(client, "ping", 4, 0) < 0) return;
    var buffer: [8]u8 = undefined;
    _ = a.Recv(server, &buffer, buffer.len, 0);
}

test "every allocation of a connection that fails is answered, and leaves nothing behind" {
    var rig = try Rig.init();
    const sys = kexec.SysBase.iface();
    const exec_lib: *exec.Library = &kexec.SysBase.lib;
    real_alloc = sys.SetFunction(exec_lib, sdk.interface.exec.LVO.AllocMem, exec.vec(failingAlloc));
    var n: u32 = 1;
    var time: u64 = 0;
    while (n < 200) : (n += 1) {
        allocations = 0;
        fail_at = n;
        connection(&rig);
        fail_at = 0;
        // Let whatever is still finishing finish.
        var rounds: usize = 0;
        while (rounds < 50) : (rounds += 1) {
            time = @max(time + 1, rig.earliest() orelse break);
            rig.advance(time);
        }
        try testing.expect(rig.a.stack.sockets.isEmpty());
        try testing.expectEqual(@as(u32, 0), rig.a.stack.frames.used());
        if (allocations < n) break;
    }
    // Two sockets and a third made by the listener, their connection
    // blocks and rings, and the frames: every one of them failed once.
    try testing.expect(n > 12 and n < 200);
    _ = sys.SetFunction(exec_lib, sdk.interface.exec.LVO.AllocMem, real_alloc.?);
    try rig.deinit();
}

// --- capture ----------------------------------------------------------------------

/// An echo request to B from A's raw socket `raw`.
fn echoToB(a: *SocketBase, raw: i32, sequence: u8) !void {
    var echo: [12]u8 = .{ 8, 0, 0, 0, 0x12, 0x34, 0, sequence, 'p', 'i', 'n', 'g' };
    _ip.put16(&echo, 2, _ip.finish(_ip.sum(0, &echo)));
    var to = at(address_b, 0);
    try testing.expectEqual(@as(i32, echo.len), a.SendTo(raw, &echo, echo.len, 0, to.anyConst(), @sizeOf(bsd.sockaddr_in)));
}

test "a capture socket sees what goes out and what comes in, and counts what it had no room for" {
    var rig = try Rig.init();
    const a = rig.a.sb;
    @memcpy(rig.a.interface.name[0..4], "eth0");
    const capture = a.Socket(bsd.PF_PACKET, bsd.SOCK_RAW, 0);
    try testing.expect(capture >= 0);
    try testing.expectEqual(@as(i32, 0), a.SetSockOpt(capture, bsd.SOL_SOCKET, bsd.SO_BINDTODEVICE, "eth0", 4));
    try testing.expectEqual(@as(i32, -1), a.SetSockOpt(capture, bsd.SOL_SOCKET, bsd.SO_BINDTODEVICE, "eth9", 4));
    try testing.expectEqual(bsd.ENXIO, a.Errno());
    var nowhere = at(address_b, 7);
    try testing.expectEqual(@as(i32, -1), a.SendTo(capture, "x", 1, 0, nowhere.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(bsd.EOPNOTSUPP, a.Errno());
    try testing.expectEqual(@as(i32, -1), a.Bind(capture, nowhere.anyConst(), @sizeOf(bsd.sockaddr_in)));
    const raw = a.Socket(bsd.PF_INET, bsd.SOCK_RAW, bsd.IPPROTO_ICMP);

    try echoToB(a, raw, 1);
    rig.pump();
    const header_bytes = @sizeOf(bsd.CaptureHeader);
    var buffer: [1600]u8 = undefined;
    for ([_]u8{ bsd.CAPTURE_OUT, bsd.CAPTURE_IN }, [_]u8{ 8, 0 }) |direction, icmp_type| {
        const got = a.Recv(capture, &buffer, buffer.len, 0);
        try testing.expectEqual(@as(i32, header_bytes + 14 + 20 + 12), got);
        const header: *align(1) const bsd.CaptureHeader = @ptrCast(&buffer);
        try testing.expectEqual(direction, header.direction);
        try testing.expectEqual(bsd.CAPTURE_LINK_ETHERNET, header.link);
        try testing.expectEqual(@as(u32, 14 + 20 + 12), header.length);
        try testing.expectEqual(@as(u32, 0), header.dropped);
        try testing.expectEqualStrings("eth0", std.mem.sliceTo(&header.interface, 0));
        const frame = buffer[header_bytes..];
        try testing.expectEqualSlices(u8, &.{ 0x08, 0x00 }, frame[12..14]);
        try testing.expectEqual(@as(u8, 0x45), frame[14]);
        try testing.expectEqual(icmp_type, frame[14 + 20]);
    }
    // Only its own interface's: lo0 is not.
    var own = at(address_a, 9);
    const udp = a.Socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    try testing.expectEqual(@as(i32, 1), a.SendTo(udp, "x", 1, 0, own.anyConst(), @sizeOf(bsd.sockaddr_in)));
    var ready: bsd.fd_set = .{};
    ready.set(capture);
    var no_wait: bsd.timeval = .{};
    try testing.expectEqual(@as(i32, 0), a.WaitSelect(capture + 1, &ready, null, null, &no_wait, null));

    // Ten echoes both ways, unread: sixteen kept, four counted.
    for (0..10) |sequence| try echoToB(a, raw, @intCast(sequence + 2));
    rig.pump();
    for (0..16) |_| try testing.expect(a.Recv(capture, &buffer, buffer.len, 0) > 0);
    try echoToB(a, raw, 99);
    try testing.expect(a.Recv(capture, &buffer, buffer.len, 0) > 0);
    const header: *align(1) const bsd.CaptureHeader = @ptrCast(&buffer);
    try testing.expectEqual(@as(u32, 4), header.dropped);
    rig.pump();

    _ = a.CloseSocket(udp);
    _ = a.CloseSocket(raw);
    _ = a.CloseSocket(capture);
    try testing.expectEqual(@as(u32, 0), rig.a.stack.captures);
    try rig.deinit();
}
