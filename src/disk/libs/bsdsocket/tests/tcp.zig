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
            _ip.input(target.stack, target.interface, frame);
        }
    }

    /// Both stacks' timers run to `now`.
    fn advance(rig: *Rig, now: u64) void {
        _timer.run(rig.a.stack, now);
        _timer.run(rig.b.stack, now);
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
