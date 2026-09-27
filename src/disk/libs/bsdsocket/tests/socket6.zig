// SPDX-License-Identifier: MIT
//! Host tests of AF_INET6 sockets, over lo0 (`::1` and `127.0.0.1`):
//! datagrams both ways, one socket taking both families, IPV6_V6ONLY,
//! which binds clash, a connection, a raw ICMPv6 echo, and the interface
//! indexes a scope names.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const ExecBase = sdk.interface.exec.ExecBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const bsdsocket = @import("../bsdsocket_init.zig");
const _base = @import("../bsdsocket_base.zig");
const _ip = @import("../ip/_ip.zig");
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;

const testing = std.testing;

/// Room for four connections' rings, more than the ROM's test RAM has.
var lent: [256 * 1024]u8 align(16) = undefined;

const Rig = struct {
    kub: *utility_library.UtilityBase,
    region: *exec.MemHeader,
    sys: *ExecBase,
    stack: *exec.Library,
    sb: *SocketBase,

    fn init() !Rig {
        const kub = try utility_library.setUp();
        const sys = kexec.SysBase.iface();
        const region = sys.AddMemList(lent.len, exec.MEMF_ANY, 0, &lent, "lent").?;
        const made = kexec.InitResident(kexec.SysBase, &bsdsocket.bsdsocket_library_tag, null) orelse return error.NoLibrary;
        const stack: *exec.Library = @ptrCast(@alignCast(made));
        // Connections without the stack task: lo0 answers at once.
        _base.stackBase(stack).no_task = 1;
        const sb: *SocketBase = @ptrCast(sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse return error.NoBase);
        return .{ .kub = kub, .region = region, .sys = sys, .stack = stack, .sb = sb };
    }

    fn deinit(rig: *Rig) !void {
        rig.sys.CloseLibrary(rig.sb.lib());
        _ = rig.sys.RemLibrary(rig.stack);
        try testing.expectEqual(@intFromPtr(rig.region.upper) - @intFromPtr(rig.region.lower), rig.region.free);
        rig.sys.Remove(&rig.region.node);
        try utility_library.tearDown(rig.kub);
        kexec.deinit();
    }

    /// `us` microseconds gone by on the stack's clock, its timers run.
    fn pass(rig: *Rig, us: u64) void {
        const stack = _base.stackBase(rig.stack);
        const end = stack.fixed_time + us;
        while (stack.fixed_time < end) {
            stack.fixed_time = @min(end, stack.fixed_time + 100_000);
            @import("../timer/_timer.zig").run(stack, stack.fixed_time);
        }
    }

    fn socket(rig: *Rig, domain: i32, socket_type: i32, protocol: i32) !i32 {
        const made = rig.sb.Socket(domain, socket_type, protocol);
        if (made < 0) return error.NoSocket;
        _ = rig.sb.IoctlSocket(made, bsd.FIONBIO, @constCast(&@as(u32, 1)));
        return made;
    }
};

fn loopback6(port: u16) bsd.sockaddr_in6 {
    return .{ .sin6_port = bsd.htons(port), .sin6_addr = bsd.in6addr_loopback };
}

fn loopback4(port: u16) bsd.sockaddr_in {
    return .{ .sin_port = bsd.htons(port), .sin_addr = .{ .s_addr = bsd.htonl(bsd.INADDR_LOOPBACK) } };
}

fn any6(port: u16) bsd.sockaddr_in6 {
    return .{ .sin6_port = bsd.htons(port) };
}

const mapped_loopback = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1 };

test "datagrams over ::1, and an AF_INET6 socket takes IPv4 too" {
    var rig = try Rig.init();
    const sb = rig.sb;
    const server = try rig.socket(bsd.PF_INET6, bsd.SOCK_DGRAM, 0);
    var here = any6(7000);
    try testing.expectEqual(@as(i32, 0), sb.Bind(server, here.anyConst(), @sizeOf(bsd.sockaddr_in6)));
    var name: bsd.sockaddr_in6 = .{};
    var name_length: u32 = @sizeOf(bsd.sockaddr_in6);
    try testing.expectEqual(@as(i32, 0), sb.GetSockName(server, name.any(), &name_length));
    try testing.expectEqual(@as(u32, @sizeOf(bsd.sockaddr_in6)), name_length);
    try testing.expectEqual(bsd.AF_INET6, name.sin6_family);
    try testing.expectEqual(bsd.htons(7000), name.sin6_port);

    const client6 = try rig.socket(bsd.PF_INET6, bsd.SOCK_DGRAM, 0);
    var to6 = loopback6(7000);
    try testing.expectEqual(@as(i32, 3), sb.SendTo(client6, "six", 3, 0, to6.anyConst(), @sizeOf(bsd.sockaddr_in6)));
    var buffer: [16]u8 = undefined;
    var from: bsd.sockaddr_in6 = .{};
    var from_length: u32 = @sizeOf(bsd.sockaddr_in6);
    try testing.expectEqual(@as(i32, 3), sb.RecvFrom(server, &buffer, buffer.len, 0, from.any(), &from_length));
    try testing.expectEqualStrings("six", buffer[0..3]);
    try testing.expectEqualSlices(u8, &bsd.in6addr_loopback.s6_addr, &from.sin6_addr.s6_addr);
    // The answer goes back the way the question came.
    try testing.expectEqual(@as(i32, 2), sb.SendTo(server, "ok", 2, 0, from.anyConst(), from_length));
    try testing.expectEqual(@as(i32, 2), sb.Recv(client6, &buffer, buffer.len, 0));

    // An IPv4 sender: the AF_INET6 socket sees it mapped.
    const client4 = try rig.socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    var to4 = loopback4(7000);
    try testing.expectEqual(@as(i32, 4), sb.SendTo(client4, "four", 4, 0, to4.anyConst(), @sizeOf(bsd.sockaddr_in)));
    from_length = @sizeOf(bsd.sockaddr_in6);
    try testing.expectEqual(@as(i32, 4), sb.RecvFrom(server, &buffer, buffer.len, 0, from.any(), &from_length));
    try testing.expectEqualSlices(u8, &mapped_loopback, &from.sin6_addr.s6_addr);
    // And answers it through the mapped address.
    try testing.expectEqual(@as(i32, 2), sb.SendTo(server, "ok", 2, 0, from.anyConst(), from_length));
    var from4: bsd.sockaddr_in = .{};
    var from4_length: u32 = @sizeOf(bsd.sockaddr_in);
    try testing.expectEqual(@as(i32, 2), sb.RecvFrom(client4, &buffer, buffer.len, 0, from4.any(), &from4_length));
    try testing.expectEqual(bsd.htons(7000), from4.sin_port);

    // An AF_INET socket takes no sockaddr_in6.
    try testing.expectEqual(@as(i32, -1), sb.SendTo(client4, "x", 1, 0, to6.anyConst(), @sizeOf(bsd.sockaddr_in6)));
    try testing.expectEqual(bsd.EAFNOSUPPORT, sb.Errno());
    try rig.deinit();
}

test "IPV6_V6ONLY keeps IPv4 away, and decides which binds clash" {
    var rig = try Rig.init();
    const sb = rig.sb;
    const both = try rig.socket(bsd.PF_INET6, bsd.SOCK_DGRAM, 0);
    var here = any6(7001);
    try testing.expectEqual(@as(i32, 0), sb.Bind(both, here.anyConst(), @sizeOf(bsd.sockaddr_in6)));
    // 0.0.0.0:7001 meets [::]:7001, which takes IPv4 too.
    const four = try rig.socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    var here4: bsd.sockaddr_in = .{ .sin_port = bsd.htons(7001) };
    try testing.expectEqual(@as(i32, -1), sb.Bind(four, here4.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(bsd.EADDRINUSE, sb.Errno());

    // An IPv6-only socket on another port leaves IPv4 free there.
    const only = try rig.socket(bsd.PF_INET6, bsd.SOCK_DGRAM, 0);
    const on: i32 = 1;
    try testing.expectEqual(@as(i32, 0), sb.SetSockOpt(only, bsd.IPPROTO_IPV6, bsd.IPV6_V6ONLY, &on, @sizeOf(i32)));
    here = any6(7002);
    try testing.expectEqual(@as(i32, 0), sb.Bind(only, here.anyConst(), @sizeOf(bsd.sockaddr_in6)));
    here4.sin_port = bsd.htons(7002);
    const four_b = try rig.socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    try testing.expectEqual(@as(i32, 0), sb.Bind(four_b, here4.anyConst(), @sizeOf(bsd.sockaddr_in)));
    // Too late to change once bound.
    try testing.expectEqual(@as(i32, -1), sb.SetSockOpt(only, bsd.IPPROTO_IPV6, bsd.IPV6_V6ONLY, &on, @sizeOf(i32)));

    // IPv4 to 7002 reaches the AF_INET socket, not the IPv6-only one.
    const client4 = try rig.socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    var to4 = loopback4(7002);
    _ = sb.SendTo(client4, "four", 4, 0, to4.anyConst(), @sizeOf(bsd.sockaddr_in));
    var buffer: [16]u8 = undefined;
    try testing.expectEqual(@as(i32, -1), sb.Recv(only, &buffer, buffer.len, 0));
    try testing.expectEqual(@as(i32, 4), sb.Recv(four_b, &buffer, buffer.len, 0));
    // And it takes no mapped address as a destination.
    var mapped: bsd.sockaddr_in6 = .{ .sin6_port = bsd.htons(9), .sin6_addr = .{ .s6_addr = mapped_loopback } };
    try testing.expectEqual(@as(i32, -1), sb.SendTo(only, "x", 1, 0, mapped.anyConst(), @sizeOf(bsd.sockaddr_in6)));
    try testing.expectEqual(bsd.EINVAL, sb.Errno());

    var value: i32 = 0;
    var size: u32 = @sizeOf(i32);
    try testing.expectEqual(@as(i32, 0), sb.GetSockOpt(only, bsd.IPPROTO_IPV6, bsd.IPV6_V6ONLY, &value, &size));
    try testing.expectEqual(@as(i32, 1), value);
    try testing.expectEqual(@as(i32, 0), sb.GetSockOpt(only, bsd.IPPROTO_IPV6, bsd.IPV6_UNICAST_HOPS, &value, &size));
    try testing.expectEqual(@as(i32, -1), value);
    try rig.deinit();
}

test "a connection over ::1, and one from IPv4 to the same listener" {
    var rig = try Rig.init();
    const sb = rig.sb;
    const listener = try rig.socket(bsd.PF_INET6, bsd.SOCK_STREAM, 0);
    var here = any6(8080);
    try testing.expectEqual(@as(i32, 0), sb.Bind(listener, here.anyConst(), @sizeOf(bsd.sockaddr_in6)));
    try testing.expectEqual(@as(i32, 0), sb.Listen(listener, 4));

    const client = try rig.socket(bsd.PF_INET6, bsd.SOCK_STREAM, 0);
    var to = loopback6(8080);
    const connected = sb.Connect(client, to.anyConst(), @sizeOf(bsd.sockaddr_in6));
    try testing.expect(connected == 0 or sb.Errno() == bsd.EINPROGRESS);
    var peer: bsd.sockaddr_in6 = .{};
    var peer_length: u32 = @sizeOf(bsd.sockaddr_in6);
    const server = sb.Accept(listener, peer.any(), &peer_length);
    try testing.expect(server >= 0);
    try testing.expectEqualSlices(u8, &bsd.in6addr_loopback.s6_addr, &peer.sin6_addr.s6_addr);
    try testing.expectEqual(@as(i32, 5), sb.Send(client, "hello", 5, 0));
    var buffer: [16]u8 = undefined;
    try testing.expectEqual(@as(i32, 5), sb.Recv(server, &buffer, buffer.len, 0));
    try testing.expectEqualStrings("hello", buffer[0..5]);

    const client4 = try rig.socket(bsd.PF_INET, bsd.SOCK_STREAM, 0);
    var to4 = loopback4(8080);
    _ = sb.Connect(client4, to4.anyConst(), @sizeOf(bsd.sockaddr_in));
    peer_length = @sizeOf(bsd.sockaddr_in6);
    const server4 = sb.Accept(listener, peer.any(), &peer_length);
    try testing.expect(server4 >= 0);
    try testing.expectEqualSlices(u8, &mapped_loopback, &peer.sin6_addr.s6_addr);
    try testing.expectEqual(@as(i32, 4), sb.Send(server4, "four", 4, 0));
    try testing.expectEqual(@as(i32, 4), sb.Recv(client4, &buffer, buffer.len, 0));
    for ([_]i32{ client, server, client4, server4, listener }) |each| _ = sb.CloseSocket(each);
    // TIME_WAIT waited out.
    rig.pass(4 * @import("../tcp/_tcp.zig").msl_us);
    try rig.deinit();
}

test "a raw ICMPv6 socket pings ::1, the stack making the checksum" {
    var rig = try Rig.init();
    const sb = rig.sb;
    const raw = try rig.socket(bsd.PF_INET6, bsd.SOCK_RAW, bsd.IPPROTO_ICMPV6);
    try testing.expectEqual(@as(i32, -1), sb.Socket(bsd.PF_INET6, bsd.SOCK_RAW, bsd.IPPROTO_ICMP));
    var to = loopback6(0);
    const request = [_]u8{ 128, 0, 0, 0, 0x12, 0x34, 0, 1, 'p', 'i', 'n', 'g' };
    try testing.expectEqual(@as(i32, request.len), sb.SendTo(raw, &request, request.len, 0, to.anyConst(), @sizeOf(bsd.sockaddr_in6)));
    // The request itself, then the reply; neither with an IPv6 header.
    var buffer: [64]u8 = undefined;
    var from: bsd.sockaddr_in6 = .{};
    var from_length: u32 = @sizeOf(bsd.sockaddr_in6);
    try testing.expectEqual(@as(i32, request.len), sb.RecvFrom(raw, &buffer, buffer.len, 0, from.any(), &from_length));
    try testing.expectEqual(@as(u8, 128), buffer[0]);
    try testing.expectEqual(@as(i32, request.len), sb.RecvFrom(raw, &buffer, buffer.len, 0, from.any(), &from_length));
    try testing.expectEqual(@as(u8, 129), buffer[0]);
    try testing.expectEqualSlices(u8, request[4..], buffer[4..request.len]);
    try testing.expectEqualSlices(u8, &bsd.in6addr_loopback.s6_addr, &from.sin6_addr.s6_addr);
    try rig.deinit();
}

test "interfaces by index, and a scope that names none" {
    var rig = try Rig.init();
    const sb = rig.sb;
    try testing.expectEqual(@as(u32, 1), sb.If_NameToIndex("lo0"));
    try testing.expectEqual(@as(u32, 0), sb.If_NameToIndex("eth9"));
    try testing.expectEqual(bsd.ENXIO, sb.Errno());
    var name: [bsd.IFNAMSIZ]u8 = undefined;
    try testing.expectEqualStrings("lo0", std.mem.span(sb.If_IndexToName(1, &name).?));
    try testing.expect(sb.If_IndexToName(3, &name) == null);

    const socket = try rig.socket(bsd.PF_INET6, bsd.SOCK_DGRAM, 0);
    var to: bsd.sockaddr_in6 = .{ .sin6_port = bsd.htons(9), .sin6_scope_id = 3 };
    to.sin6_addr.s6_addr[0] = 0xfe;
    to.sin6_addr.s6_addr[1] = 0x80;
    to.sin6_addr.s6_addr[15] = 2;
    try testing.expectEqual(@as(i32, -1), sb.SendTo(socket, "x", 1, 0, to.anyConst(), @sizeOf(bsd.sockaddr_in6)));
    try testing.expectEqual(bsd.ENXIO, sb.Errno());
    try rig.deinit();
}

// --- GetAddrInfo --------------------------------------------------------------

fn entries(list: ?*bsd.addrinfo) usize {
    var count: usize = 0;
    var entry = list;
    while (entry) |each| : (entry = each.ai_next) count += 1;
    return count;
}

test "GetAddrInfo: addresses as text, services, and both socket types" {
    var rig = try Rig.init();
    const sb = rig.sb;
    var list: ?*bsd.addrinfo = null;
    const stream: bsd.addrinfo = .{ .ai_socktype = bsd.SOCK_STREAM };
    try testing.expectEqual(@as(i32, 0), sb.GetAddrInfo("::1", "80", &stream, &list));
    try testing.expectEqual(@as(usize, 1), entries(list));
    const first = list.?;
    try testing.expectEqual(@as(i32, bsd.AF_INET6), first.ai_family);
    try testing.expectEqual(bsd.IPPROTO_TCP, first.ai_protocol);
    try testing.expectEqual(@as(u32, @sizeOf(bsd.sockaddr_in6)), first.ai_addrlen);
    const six: *const bsd.sockaddr_in6 = @ptrCast(@alignCast(first.ai_addr.?));
    try testing.expectEqual(bsd.htons(80), six.sin6_port);
    try testing.expectEqualSlices(u8, &bsd.in6addr_loopback.s6_addr, &six.sin6_addr.s6_addr);
    sb.FreeAddrInfo(first);

    // No socket type: TCP and UDP; a service by name.
    try testing.expectEqual(@as(i32, 0), sb.GetAddrInfo("127.0.0.1", "http", null, &list));
    try testing.expectEqual(@as(usize, 2), entries(list));
    try testing.expectEqual(@as(i32, bsd.AF_INET), list.?.ai_family);
    try testing.expectEqual(bsd.SOCK_STREAM, list.?.ai_socktype);
    try testing.expectEqual(bsd.SOCK_DGRAM, list.?.ai_next.?.ai_socktype);
    const four: *const bsd.sockaddr_in = @ptrCast(@alignCast(list.?.ai_addr.?));
    try testing.expectEqual(bsd.htons(80), four.sin_port);
    try testing.expectEqual(bsd.htonl(bsd.INADDR_LOOPBACK), four.sin_addr.s_addr);
    sb.FreeAddrInfo(list.?);

    // Mapped, for AF_INET6 that asks for it.
    const mapped: bsd.addrinfo = .{ .ai_family = bsd.AF_INET6, .ai_socktype = bsd.SOCK_DGRAM, .ai_flags = bsd.AI_V4MAPPED };
    try testing.expectEqual(@as(i32, 0), sb.GetAddrInfo("127.0.0.1", "53", &mapped, &list));
    const as_six: *const bsd.sockaddr_in6 = @ptrCast(@alignCast(list.?.ai_addr.?));
    try testing.expectEqualSlices(u8, &mapped_loopback, &as_six.sin6_addr.s6_addr);
    sb.FreeAddrInfo(list.?);

    // A link-local address with its interface.
    try testing.expectEqual(@as(i32, 0), sb.GetAddrInfo("fe80::1%lo0", "7", &stream, &list));
    try testing.expectEqual(@as(u32, 1), @as(*const bsd.sockaddr_in6, @ptrCast(@alignCast(list.?.ai_addr.?))).sin6_scope_id);
    sb.FreeAddrInfo(list.?);
    try rig.deinit();
}

test "GetAddrInfo: this machine, localhost in RFC 6724's order, and what it refuses" {
    var rig = try Rig.init();
    const sb = rig.sb;
    var list: ?*bsd.addrinfo = null;
    const passive: bsd.addrinfo = .{ .ai_socktype = bsd.SOCK_STREAM, .ai_flags = bsd.AI_PASSIVE };
    try testing.expectEqual(@as(i32, 0), sb.GetAddrInfo(null, "8080", &passive, &list));
    try testing.expectEqual(@as(usize, 2), entries(list));
    try testing.expectEqual(@as(i32, bsd.AF_INET6), list.?.ai_family);
    const any: *const bsd.sockaddr_in6 = @ptrCast(@alignCast(list.?.ai_addr.?));
    try testing.expectEqualSlices(u8, &bsd.in6addr_any.s6_addr, &any.sin6_addr.s6_addr);
    sb.FreeAddrInfo(list.?);

    // localhost: ::1 before 127.0.0.1, its precedence being higher.
    const named: bsd.addrinfo = .{ .ai_socktype = bsd.SOCK_STREAM, .ai_flags = bsd.AI_CANONNAME };
    try testing.expectEqual(@as(i32, 0), sb.GetAddrInfo("localhost", "80", &named, &list));
    try testing.expectEqual(@as(usize, 2), entries(list));
    try testing.expectEqual(@as(i32, bsd.AF_INET6), list.?.ai_family);
    try testing.expectEqual(@as(i32, bsd.AF_INET), list.?.ai_next.?.ai_family);
    try testing.expectEqualStrings("localhost", std.mem.span(list.?.ai_canonname.?));
    sb.FreeAddrInfo(list.?);

    try testing.expectEqual(bsd.EAI_NONAME, sb.GetAddrInfo(null, null, null, &list));
    try testing.expect(list == null);
    const numeric: bsd.addrinfo = .{ .ai_flags = bsd.AI_NUMERICHOST };
    try testing.expectEqual(bsd.EAI_NONAME, sb.GetAddrInfo("example.org", "80", &numeric, &list));
    const bad_family: bsd.addrinfo = .{ .ai_family = 99 };
    try testing.expectEqual(bsd.EAI_FAMILY, sb.GetAddrInfo("::1", "80", &bad_family, &list));
    const raw: bsd.addrinfo = .{ .ai_socktype = bsd.SOCK_RAW };
    try testing.expectEqual(bsd.EAI_SOCKTYPE, sb.GetAddrInfo("::1", "80", &raw, &list));
    try testing.expectEqual(bsd.EAI_SERVICE, sb.GetAddrInfo("::1", "gopher", null, &list));
    const v4_only: bsd.addrinfo = .{ .ai_family = bsd.AF_INET };
    try testing.expectEqual(bsd.EAI_NONAME, sb.GetAddrInfo("::1", "80", &v4_only, &list));
    // No name server to ask.
    try testing.expectEqual(bsd.EAI_FAIL, sb.GetAddrInfo("example.org", "80", null, &list));
    try rig.deinit();
}

test "a datagram larger than the link goes in fragments and comes back whole" {
    var rig = try Rig.init();
    const sb = rig.sb;
    const server = try rig.socket(bsd.PF_INET6, bsd.SOCK_DGRAM, 0);
    var here = any6(7010);
    try testing.expectEqual(@as(i32, 0), sb.Bind(server, here.anyConst(), @sizeOf(bsd.sockaddr_in6)));
    var size: i32 = 64 * 1024;
    _ = sb.SetSockOpt(server, bsd.SOL_SOCKET, bsd.SO_RCVBUF, &size, @sizeOf(i32));
    const client = try rig.socket(bsd.PF_INET6, bsd.SOCK_DGRAM, 0);
    var big: [5000]u8 = undefined;
    for (&big, 0..) |*byte, at| byte.* = @truncate(at *% 13);
    var to = loopback6(7010);
    try testing.expectEqual(@as(i32, big.len), sb.SendTo(client, &big, big.len, 0, to.anyConst(), @sizeOf(bsd.sockaddr_in6)));
    var got: [6000]u8 = undefined;
    try testing.expectEqual(@as(i32, big.len), sb.Recv(server, &got, got.len, 0));
    try testing.expectEqualSlices(u8, &big, got[0..big.len]);
    const stack = _base.stackBase(rig.stack);
    try testing.expect(stack.counts.ip6_fragments_sent >= 4);
    try testing.expectEqual(@as(u32, 1), stack.counts.ip6_reassembled);
    // IPv4 still sends nothing in fragments.
    const four = try rig.socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    var to4 = loopback4(7010);
    try testing.expectEqual(@as(i32, -1), sb.SendTo(four, &big, big.len, 0, to4.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(bsd.EMSGSIZE, sb.Errno());
    try rig.deinit();
}

test "name servers of both families, as GetNetworkStatistics lists them" {
    var rig = try Rig.init();
    const sb = rig.sb;
    try testing.expectEqual(@as(i32, 0), sb.AddDomainNameServer(sb.Inet_Addr("9.9.9.9")));
    const six = @import("../ip6/address.zig").parse("2620:fe::fe").?;
    try testing.expect(@import("../names/_names.zig").addServer(_base.stackBase(rig.stack), six));
    var table: [4]bsd.NameServerInfo = undefined;
    try testing.expectEqual(@as(i32, 2), sb.GetNetworkStatistics(bsd.NETSTATUS_NAMESERVERS, &table, @sizeOf(@TypeOf(table))));
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 9, 9, 9, 9 }, &table[0].address.s6_addr);
    try testing.expectEqualSlices(u8, &six.bytes, &table[1].address.s6_addr);
    try testing.expectEqual(bsd.NAMESERVER_GIVEN, table[1].origin);
    try testing.expectEqual(@as(i32, 0), sb.RemoveDomainNameServer(sb.Inet_Addr("9.9.9.9")));
    try testing.expectEqual(@as(i32, 1), sb.GetNetworkStatistics(bsd.NETSTATUS_NAMESERVERS, &table, @sizeOf(@TypeOf(table))));
    try rig.deinit();
}

test "names the other way: GetHostByAddr for IPv6, GetNameInfo, the PTR question" {
    var rig = try Rig.init();
    const sb = rig.sb;
    const resolver = @import("../names/resolver.zig");
    const parse = @import("../ip6/address.zig").parse;
    var question: [80]u8 = undefined;
    const asked = question[0..resolver.reverseName(parse("2001:db8::567:89ab").?, &question)];
    try testing.expectEqualStrings("b.a.9.8.7.6.5.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa", asked);
    try testing.expectEqualStrings("4.3.2.1.in-addr.arpa", question[0..resolver.reverseName(@import("../ip6/address.zig").Address.fromV4(0x0102_0304), &question)]);

    const host = sb.GetHostByAddr(&bsd.in6addr_loopback, 16, bsd.AF_INET6).?;
    try testing.expectEqualStrings("localhost", std.mem.span(host.h_name.?));
    try testing.expectEqual(@as(i32, bsd.AF_INET6), host.h_addrtype);
    try testing.expectEqual(@as(i32, 16), host.h_length);
    try testing.expectEqualSlices(u8, &bsd.in6addr_loopback.s6_addr, host.h_addr_list.?[0].?[0..16]);
    try testing.expect(sb.GetHostByAddr(&bsd.in6addr_loopback, 4, bsd.AF_INET6) == null);

    var name: [bsd.NI_MAXHOST]u8 = undefined;
    var service: [bsd.NI_MAXSERV]u8 = undefined;
    var six = loopback6(80);
    try testing.expectEqual(@as(i32, 0), sb.GetNameInfo(six.anyConst(), @sizeOf(bsd.sockaddr_in6), &name, name.len, &service, service.len, 0));
    try testing.expectEqualStrings("localhost", std.mem.sliceTo(&name, 0));
    try testing.expectEqualStrings("http", std.mem.sliceTo(&service, 0));
    try testing.expectEqual(@as(i32, 0), sb.GetNameInfo(six.anyConst(), @sizeOf(bsd.sockaddr_in6), &name, name.len, &service, service.len, bsd.NI_NUMERICHOST | bsd.NI_NUMERICSERV));
    try testing.expectEqualStrings("::1", std.mem.sliceTo(&name, 0));
    try testing.expectEqualStrings("80", std.mem.sliceTo(&service, 0));
    // A link-local address with its interface.
    var link: bsd.sockaddr_in6 = .{ .sin6_port = bsd.htons(7), .sin6_addr = .{ .s6_addr = parse("fe80::1").?.bytes }, .sin6_scope_id = 1 };
    try testing.expectEqual(@as(i32, 0), sb.GetNameInfo(link.anyConst(), @sizeOf(bsd.sockaddr_in6), &name, name.len, null, 0, bsd.NI_NUMERICHOST));
    try testing.expectEqualStrings("fe80::1%lo0", std.mem.sliceTo(&name, 0));
    // IPv4, and IPv4 mapped.
    var four = loopback4(23);
    try testing.expectEqual(@as(i32, 0), sb.GetNameInfo(four.anyConst(), @sizeOf(bsd.sockaddr_in), &name, name.len, &service, service.len, 0));
    try testing.expectEqualStrings("localhost", std.mem.sliceTo(&name, 0));
    try testing.expectEqualStrings("telnet", std.mem.sliceTo(&service, 0));
    var mapped: bsd.sockaddr_in6 = .{ .sin6_addr = .{ .s6_addr = mapped_loopback } };
    try testing.expectEqual(@as(i32, 0), sb.GetNameInfo(mapped.anyConst(), @sizeOf(bsd.sockaddr_in6), &name, name.len, null, 0, bsd.NI_NUMERICHOST));
    try testing.expectEqualStrings("127.0.0.1", std.mem.sliceTo(&name, 0));
    // No name to be had: the address, unless a name is required.
    var far: bsd.sockaddr_in6 = .{ .sin6_addr = .{ .s6_addr = parse("2001:db8::1").?.bytes } };
    try testing.expectEqual(@as(i32, 0), sb.GetNameInfo(far.anyConst(), @sizeOf(bsd.sockaddr_in6), &name, name.len, null, 0, 0));
    try testing.expectEqualStrings("2001:db8::1", std.mem.sliceTo(&name, 0));
    try testing.expectEqual(bsd.EAI_NONAME, sb.GetNameInfo(far.anyConst(), @sizeOf(bsd.sockaddr_in6), &name, name.len, null, 0, bsd.NI_NAMEREQD));
    var small: [4]u8 = undefined;
    try testing.expectEqual(bsd.EAI_OVERFLOW, sb.GetNameInfo(far.anyConst(), @sizeOf(bsd.sockaddr_in6), &small, small.len, null, 0, bsd.NI_NUMERICHOST));
    try testing.expectEqual(bsd.EAI_FAMILY, sb.GetNameInfo(far.anyConst(), 8, &name, name.len, null, 0, 0));
    try rig.deinit();
}
