// SPDX-License-Identifier: MIT
//! Host tests of bsdsocket.library as a whole: the library made from its
//! ROM tag on the ROM's exec and utility.library, opened as a program
//! opens it, and spoken to through its jump table. Everything here goes
//! over the loopback interface, which needs no device.
//!
//! The last test runs a whole exchange again and again with exec's
//! AllocMem made to fail at the first allocation, then the second, and so
//! on, until it runs through without one failing: every path that runs
//! out of memory is walked at least once, and each must answer an error
//! and leave nothing behind.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const bsdsocket = @import("../bsdsocket_init.zig");
const _base = @import("../bsdsocket_base.zig");
const _ip = @import("../ip/_ip.zig");
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;

const testing = std.testing;

test {
    _ = @import("../bsdsocket_lvo.zig");
}

/// exec, utility.library and the stack; opened bases are the tests'.
const Rig = struct {
    kub: *utility_library.UtilityBase,
    sys: *ExecBase,
    stack: *exec.Library,

    fn init() !Rig {
        const kub = try utility_library.setUp();
        const sys = kexec.SysBase.iface();
        const made = kexec.InitResident(kexec.SysBase, &bsdsocket.bsdsocket_library_tag, null) orelse return error.NoLibrary;
        return .{ .kub = kub, .sys = sys, .stack = @ptrCast(@alignCast(made)) };
    }

    fn open(rig: *Rig) !*SocketBase {
        const lib = rig.sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse return error.NoBase;
        return @ptrCast(lib);
    }

    fn close(rig: *Rig, sb: *SocketBase) void {
        rig.sys.CloseLibrary(sb.lib());
    }

    fn stackBase(rig: *Rig) *_base.StackBase {
        return _base.stackBase(rig.stack);
    }

    /// The stack expunged, and everything taken given back.
    fn deinit(rig: *Rig) !void {
        _ = rig.sys.RemLibrary(rig.stack);
        try utility_library.tearDown(rig.kub);
        kexec.deinit();
    }
};

fn loopback(port: u16) bsd.sockaddr_in {
    return .{ .sin_port = bsd.htons(port), .sin_addr = .{ .s_addr = bsd.htonl(bsd.INADDR_LOOPBACK) } };
}

fn udp(sb: *SocketBase) !i32 {
    const socket = sb.Socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    if (socket < 0) return error.NoSocket;
    return socket;
}

test "two openers exchange a datagram over lo0" {
    var rig = try Rig.init();
    const server = try rig.open();
    const client = try rig.open();
    try testing.expect(server != client);

    const listening = try udp(server);
    var here = loopback(7000);
    try testing.expectEqual(@as(i32, 0), server.Bind(listening, here.anyConst(), @sizeOf(bsd.sockaddr_in)));

    const talking = try udp(client);
    const text = "hello";
    try testing.expectEqual(@as(i32, text.len), client.SendTo(talking, text, text.len, 0, here.anyConst(), @sizeOf(bsd.sockaddr_in)));

    var own: bsd.sockaddr_in = .{};
    var own_length: u32 = @sizeOf(bsd.sockaddr_in);
    try testing.expectEqual(@as(i32, 0), client.GetSockName(talking, own.any(), &own_length));
    try testing.expect(bsd.ntohs(own.sin_port) >= _base.port_first);

    var waiting: u32 = 0;
    try testing.expectEqual(@as(i32, 0), server.IoctlSocket(listening, bsd.FIONREAD, &waiting));
    try testing.expectEqual(@as(u32, text.len), waiting);

    var buffer: [32]u8 = undefined;
    var from: bsd.sockaddr_in = .{};
    var from_length: u32 = @sizeOf(bsd.sockaddr_in);
    const got = server.RecvFrom(listening, &buffer, buffer.len, 0, from.any(), &from_length);
    try testing.expectEqual(@as(i32, text.len), got);
    try testing.expectEqualStrings(text, buffer[0..text.len]);
    try testing.expectEqual(own.sin_port, from.sin_port);
    try testing.expectEqual(bsd.htonl(bsd.INADDR_LOOPBACK), from.sin_addr.s_addr);

    // The answer goes back to where the question came from.
    try testing.expectEqual(@as(i32, 2), server.SendTo(listening, "ok", 2, 0, from.anyConst(), from_length));
    try testing.expectEqual(@as(i32, 2), client.Recv(talking, &buffer, buffer.len, 0));
    try testing.expectEqualStrings("ok", buffer[0..2]);

    try testing.expectEqual(@as(u64, 2), rig.stackBase().counts.udp_received);
    rig.close(client);
    rig.close(server);
    try rig.deinit();
}

test "what the calls refuse, and why" {
    var rig = try Rig.init();
    const sb = try rig.open();
    try testing.expectEqual(@as(i32, -1), sb.Socket(bsd.PF_INET, 5, 0));
    try testing.expectEqual(bsd.ESOCKTNOSUPPORT, sb.Errno());
    try testing.expectEqual(@as(i32, -1), sb.CloseSocket(5));
    try testing.expectEqual(bsd.EBADF, sb.Errno());

    const first = try udp(sb);
    const second = try udp(sb);
    var here = loopback(7001);
    try testing.expectEqual(@as(i32, 0), sb.Bind(first, here.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(@as(i32, -1), sb.Bind(second, here.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(bsd.EADDRINUSE, sb.Errno());
    var elsewhere: bsd.sockaddr_in = .{ .sin_port = bsd.htons(7002), .sin_addr = .{ .s_addr = sb.Inet_Addr("10.9.8.7") } };
    try testing.expectEqual(@as(i32, -1), sb.Bind(second, elsewhere.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(bsd.EADDRNOTAVAIL, sb.Errno());

    // Nothing to send to without an address, nothing to send it on.
    try testing.expectEqual(@as(i32, -1), sb.Send(second, "x", 1, 0));
    try testing.expectEqual(bsd.EDESTADDRREQ, sb.Errno());
    try testing.expectEqual(@as(i32, -1), sb.SendTo(second, "x", 1, 0, elsewhere.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(bsd.ENETUNREACH, sb.Errno());
    // lo0's MTU less the headers is the most one datagram carries.
    var big: [1473]u8 = @splat(0);
    try testing.expectEqual(@as(i32, -1), sb.SendTo(second, &big, big.len, 0, here.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(bsd.EMSGSIZE, sb.Errno());
    try testing.expectEqual(@as(i32, 1472), sb.SendTo(second, &big, 1472, 0, here.anyConst(), @sizeOf(bsd.sockaddr_in)));

    // A socket that does not wait says so, and a port nobody has takes
    // the datagram and drops it.
    var never: i32 = 1;
    try testing.expectEqual(@as(i32, 0), sb.IoctlSocket(second, bsd.FIONBIO, &never));
    try testing.expectEqual(@as(i32, -1), sb.Recv(second, &big, big.len, 0));
    try testing.expectEqual(bsd.EWOULDBLOCK, sb.Errno());
    var nobody = loopback(7999);
    try testing.expectEqual(@as(i32, 1), sb.SendTo(second, "x", 1, 0, nobody.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(@as(u32, 1), rig.stackBase().counts.udp_no_port);

    // The errno also goes where the program asked.
    var errno: i32 = 0;
    sb.SetErrnoPtr(&errno, @sizeOf(i32));
    try testing.expectEqual(@as(i32, -1), sb.CloseSocket(63));
    try testing.expectEqual(bsd.EBADF, errno);
    rig.close(sb);
    try rig.deinit();
}

test "a full queue drops what comes, and SO_REUSEADDR shares a port" {
    var rig = try Rig.init();
    const sb = try rig.open();
    const receiving = try udp(sb);
    const sending = try udp(sb);
    const small: i32 = 10;
    try testing.expectEqual(@as(i32, 0), sb.SetSockOpt(receiving, bsd.SOL_SOCKET, bsd.SO_RCVBUF, &small, @sizeOf(i32)));
    var here = loopback(7003);
    try testing.expectEqual(@as(i32, 0), sb.Bind(receiving, here.anyConst(), @sizeOf(bsd.sockaddr_in)));
    _ = sb.SendTo(sending, "12345678", 8, 0, here.anyConst(), @sizeOf(bsd.sockaddr_in));
    _ = sb.SendTo(sending, "12345678", 8, 0, here.anyConst(), @sizeOf(bsd.sockaddr_in));
    try testing.expectEqual(@as(u32, 1), rig.stackBase().counts.udp_full);

    var value: i32 = 0;
    var size: u32 = @sizeOf(i32);
    try testing.expectEqual(@as(i32, 0), sb.GetSockOpt(receiving, bsd.SOL_SOCKET, bsd.SO_RCVBUF, &value, &size));
    try testing.expectEqual(small, value);
    try testing.expectEqual(@as(i32, 0), sb.GetSockOpt(receiving, bsd.SOL_SOCKET, bsd.SO_TYPE, &value, &size));
    try testing.expectEqual(bsd.SOCK_DGRAM, value);

    const on: i32 = 1;
    const one = try udp(sb);
    const two = try udp(sb);
    var shared = loopback(7004);
    _ = sb.SetSockOpt(one, bsd.SOL_SOCKET, bsd.SO_REUSEADDR, &on, @sizeOf(i32));
    _ = sb.SetSockOpt(two, bsd.SOL_SOCKET, bsd.SO_REUSEADDR, &on, @sizeOf(i32));
    try testing.expectEqual(@as(i32, 0), sb.Bind(one, shared.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(@as(i32, 0), sb.Bind(two, shared.anyConst(), @sizeOf(bsd.sockaddr_in)));
    rig.close(sb);
    try rig.deinit();
}

test "a connected socket takes datagrams from its peer only" {
    var rig = try Rig.init();
    const sb = try rig.open();
    const connected = try udp(sb);
    const peer = try udp(sb);
    const stranger = try udp(sb);
    var peer_address = loopback(7005);
    var connected_address = loopback(7006);
    try testing.expectEqual(@as(i32, 0), sb.Bind(peer, peer_address.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(@as(i32, 0), sb.Bind(connected, connected_address.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(@as(i32, 0), sb.Connect(connected, peer_address.anyConst(), @sizeOf(bsd.sockaddr_in)));

    var name: bsd.sockaddr_in = .{};
    var length: u32 = @sizeOf(bsd.sockaddr_in);
    try testing.expectEqual(@as(i32, 0), sb.GetPeerName(connected, name.any(), &length));
    try testing.expectEqual(peer_address.sin_port, name.sin_port);
    try testing.expectEqual(@as(i32, -1), sb.GetPeerName(peer, name.any(), &length));
    try testing.expectEqual(bsd.ENOTCONN, sb.Errno());
    try testing.expectEqual(@as(i32, -1), sb.SendTo(connected, "x", 1, 0, peer_address.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(bsd.EISCONN, sb.Errno());

    _ = sb.SendTo(stranger, "no", 2, 0, connected_address.anyConst(), @sizeOf(bsd.sockaddr_in));
    try testing.expectEqual(@as(u32, 1), rig.stackBase().counts.udp_no_port);
    _ = sb.SendTo(peer, "yes", 3, 0, connected_address.anyConst(), @sizeOf(bsd.sockaddr_in));
    try testing.expectEqual(@as(i32, 2), sb.Send(connected, "hi", 2, 0));
    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(i32, 3), sb.Recv(connected, &buffer, buffer.len, 0));
    try testing.expectEqualStrings("yes", buffer[0..3]);
    try testing.expectEqual(@as(i32, 2), sb.Recv(peer, &buffer, buffer.len, 0));
    rig.close(sb);
    try rig.deinit();
}

test "WaitSelect answers the sockets that are ready, and looks without waiting on a zero timeout" {
    var rig = try Rig.init();
    const sb = try rig.open();
    const quiet = try udp(sb);
    const busy = try udp(sb);
    var busy_address = loopback(7007);
    _ = sb.Bind(busy, busy_address.anyConst(), @sizeOf(bsd.sockaddr_in));
    _ = sb.SendTo(quiet, "x", 1, 0, busy_address.anyConst(), @sizeOf(bsd.sockaddr_in));

    var read: bsd.fd_set = .{};
    read.set(quiet);
    read.set(busy);
    var write: bsd.fd_set = .{};
    write.set(quiet);
    var signals: u32 = exec.SIGBREAKF_CTRL_F;
    try testing.expectEqual(@as(i32, 2), sb.WaitSelect(busy + 1, &read, &write, null, null, &signals));
    try testing.expect(read.isSet(busy) and !read.isSet(quiet) and write.isSet(quiet));
    try testing.expectEqual(@as(u32, 0), signals);

    var buffer: [4]u8 = undefined;
    _ = sb.Recv(busy, &buffer, buffer.len, 0);
    read.zero();
    read.set(busy);
    var now: bsd.timeval = .{};
    try testing.expectEqual(@as(i32, 0), sb.WaitSelect(busy + 1, &read, null, null, &now, null));
    try testing.expect(!read.isSet(busy));

    read.set(40);
    try testing.expectEqual(@as(i32, -1), sb.WaitSelect(41, &read, null, null, &now, null));
    try testing.expectEqual(bsd.EBADF, sb.Errno());
    rig.close(sb);
    try rig.deinit();
}

test "closing the library closes its sockets and gives back what they held" {
    var rig = try Rig.init();
    const sb = try rig.open();
    const socket = try udp(sb);
    var here = loopback(7008);
    _ = sb.Bind(socket, here.anyConst(), @sizeOf(bsd.sockaddr_in));
    _ = sb.SendTo(socket, "left", 4, 0, here.anyConst(), @sizeOf(bsd.sockaddr_in));
    rig.close(sb);
    try testing.expectEqual(@as(u32, 0), rig.stackBase().frames.used());
    try testing.expect(rig.stackBase().sockets.isEmpty());
    try rig.deinit();
}

test "addresses as text and back, and the opener's settings" {
    var rig = try Rig.init();
    const sb = try rig.open();
    const address = sb.Inet_Addr("10.0.2.15");
    try testing.expectEqual(bsd.htonl(0x0A00_020F), address);
    try testing.expectEqualStrings("10.0.2.15", std.mem.span(sb.Inet_NtoA(address)));
    try testing.expectEqualStrings("255.0.0.1", std.mem.span(sb.Inet_NtoA(bsd.htonl(0xFF00_0001))));
    for ([_][*:0]const u8{ "10.0.2", "10.0.2.256", "1..2.3", "a.b.c.d", "1.2.3.4.5", "" }) |bad| {
        try testing.expectEqual(bsd.INADDR_NONE, sb.Inet_Addr(bad));
    }

    var break_mask: u32 = 0;
    const tags = [_]TagItem{
        .{ .tag = bsd.SBTM_SETVAL(bsd.SBTC_DTABLESIZE), .data = 8 },
        .{ .tag = bsd.SBTM_GETREF(bsd.SBTC_BREAKMASK), .data = @intFromPtr(&break_mask) },
        .{ .tag = bsd.SBTM_SETVAL(99), .data = 0 },
        .{},
    };
    try testing.expectEqual(@as(i32, 3), sb.SocketBaseTagList(&tags));
    try testing.expectEqual(@as(i32, 8), sb.GetDTableSize());
    try testing.expectEqual(exec.SIGBREAKF_CTRL_C, break_mask);
    // The table is full at 8, and cannot shrink under an open socket.
    var socket: i32 = 0;
    for (0..8) |_| socket = try udp(sb);
    try testing.expectEqual(@as(i32, -1), sb.Socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0));
    try testing.expectEqual(bsd.EMFILE, sb.Errno());
    const shrink = [_]TagItem{ .{ .tag = bsd.SBTM_SETVAL(bsd.SBTC_DTABLESIZE), .data = 4 }, .{} };
    try testing.expectEqual(@as(i32, 1), sb.SocketBaseTagList(&shrink));
    rig.close(sb);
    try rig.deinit();
}

test "Inet_NtoP and Inet_PtoN, both families, through the jump table" {
    var rig = try Rig.init();
    const sb = try rig.open();
    var in6: bsd.in6_addr = .{};
    try testing.expectEqual(@as(i32, 1), sb.Inet_PtoN(bsd.AF_INET6, "FEC0:0:0::2", &in6));
    var text: [bsd.INET6_ADDRSTRLEN]u8 = undefined;
    try testing.expectEqualStrings("fec0::2", std.mem.span(sb.Inet_NtoP(bsd.AF_INET6, &in6, &text, text.len).?));
    var in4: bsd.in_addr = .{};
    try testing.expectEqual(@as(i32, 1), sb.Inet_PtoN(bsd.AF_INET, "10.0.2.15", &in4));
    try testing.expectEqual(bsd.htonl(0x0A00_020F), in4.s_addr);
    try testing.expectEqualStrings("10.0.2.15", std.mem.span(sb.Inet_NtoP(bsd.AF_INET, &in4, &text, text.len).?));
    // Text that is no address answers 0 and leaves the address alone.
    try testing.expectEqual(@as(i32, 0), sb.Inet_PtoN(bsd.AF_INET6, "fe80::1%eth0", &in6));
    try testing.expectEqual(@as(i32, 0), sb.Inet_PtoN(bsd.AF_INET, "10.0.2", &in4));
    try testing.expectEqual(bsd.htonl(0x0A00_020F), in4.s_addr);
    // Another family is -1 and EAFNOSUPPORT; too small a buffer ENOSPC.
    try testing.expectEqual(@as(i32, -1), sb.Inet_PtoN(99, "::1", &in6));
    try testing.expectEqual(bsd.EAFNOSUPPORT, sb.Errno());
    try testing.expect(sb.Inet_NtoP(99, &in6, &text, text.len) == null);
    try testing.expectEqual(bsd.EAFNOSUPPORT, sb.Errno());
    try testing.expect(sb.Inet_NtoP(bsd.AF_INET6, &in6, &text, 7) == null);
    try testing.expectEqual(bsd.ENOSPC, sb.Errno());
    try testing.expect(sb.Inet_NtoP(bsd.AF_INET6, &in6, &text, 8) != null); // "fec0::2" and its NUL
    rig.close(sb);
    try rig.deinit();
}

test "the Internet checksum of a known IPv4 header" {
    const header = [_]u8{ 0x45, 0x00, 0x00, 0x73, 0x00, 0x00, 0x40, 0x00, 0x40, 0x11, 0xB8, 0x61, 0xC0, 0xA8, 0x00, 0x01, 0xC0, 0xA8, 0x00, 0xC7 };
    try testing.expectEqual(@as(u16, 0), _ip.finish(_ip.sum(0, &header)));
    var cleared = header;
    cleared[10] = 0;
    cleared[11] = 0;
    try testing.expectEqual(@as(u16, 0xB861), _ip.finish(_ip.sum(0, &cleared)));
}

// --- running out of memory -----------------------------------------------------------

/// exec's own AllocMem, and which allocation from now on fails: the
/// test's own state, since exec's jump table has no room for it.
var real_alloc: ?*const anyopaque = null;
var allocations: u32 = 0;
var fail_at: u32 = 0;

fn failingAlloc(sys: *ExecBase, size: usize, requirements: u32) callconv(.c) ?*anyopaque {
    allocations += 1;
    if (allocations == fail_at) return null;
    const real: sdk.interface.exec.Fn.AllocMem = @ptrCast(@alignCast(real_alloc.?));
    return real(sys, size, requirements);
}

/// An exchange over lo0 that gives up at the first error, as a program
/// would; whatever it got it gives back.
fn exchange(rig: *Rig) void {
    const server = rig.open() catch return;
    defer rig.close(server);
    const client = rig.open() catch return;
    defer rig.close(client);
    const listening = server.Socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    if (listening < 0) return;
    var here = loopback(7100);
    if (server.Bind(listening, here.anyConst(), @sizeOf(bsd.sockaddr_in)) < 0) return;
    const talking = client.Socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    if (talking < 0) return;
    if (client.SendTo(talking, "ping", 4, 0, here.anyConst(), @sizeOf(bsd.sockaddr_in)) < 0) return;
    var buffer: [8]u8 = undefined;
    var never: i32 = 1;
    _ = server.IoctlSocket(listening, bsd.FIONBIO, &never);
    _ = server.Recv(listening, &buffer, buffer.len, 0);
}

test "every allocation that fails is answered, and leaves nothing behind" {
    var rig = try Rig.init();
    const exec_lib: *exec.Library = &kexec.SysBase.lib;
    real_alloc = rig.sys.SetFunction(exec_lib, sdk.interface.exec.LVO.AllocMem, exec.vec(failingAlloc));
    var n: u32 = 1;
    while (n < 100) : (n += 1) {
        allocations = 0;
        fail_at = n;
        exchange(&rig);
        // Nothing of the exchange is still held: no socket, no frame.
        try testing.expect(rig.stackBase().sockets.isEmpty());
        try testing.expectEqual(@as(u32, 0), rig.stackBase().frames.used());
        if (allocations < n) break;
    }
    // Two bases with their tables, two sockets and a frame at least: the
    // walk went past every one of them.
    try testing.expect(n > 5 and n < 100);
    fail_at = 0;
    _ = rig.sys.SetFunction(exec_lib, sdk.interface.exec.LVO.AllocMem, real_alloc.?);
    try rig.deinit();
}
