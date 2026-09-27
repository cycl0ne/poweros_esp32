// SPDX-License-Identifier: MIT
//! Tcp: a TCP connection through bsdsocket.library, either way. Built
//! against the SDK only.
//!
//!   Tcp TO/K,PORT/K/N,TEXT/K,GET/K,LISTEN/S
//!
//! With TO - an IPv4 or IPv6 address, or a name - it connects to TO:PORT
//! (10.0.2.2:80) and sends TEXT, or with
//! GET an HTTP/1.0 request for that path; then it reads until the peer
//! closes, printing the first line it got, how many bytes came, and how
//! fast. With LISTEN it waits for one connection on PORT (2323), over
//! IPv6 or IPv4, prints where it came from, and sends back every line it gets, as it gets it,
//! until the peer closes.
//!
//! The interface `eth0` on networks/openeth.device, at 10.0.2.15/24 via
//! 10.0.2.2, is added first unless it is there: QEMU's user network.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const TimerBase = sdk.interface.timer.TimerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Tcp";
const VERSION_STRING = "\x00$VER: Tcp 1.1 (27.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TO/K,PORT/K/N,TEXT/K,GET/K,LISTEN/S";
const arg_to = 0;
const arg_port = 1;
const arg_text = 2;
const arg_get = 3;
const arg_listen = 4;

const MSG_NOLIBRARY = "Can't open %s\n";
const MSG_FAILED = "%s failed: errno %d\n";
const MSG_CONNECTED = "Connected to %s port %u\n";
const MSG_FIRST = "First line: %s\n";
const MSG_DONE = "%lu bytes in %lu ms, %lu KB/s\n";
const MSG_LISTENING = "Listening on port %u\n";
const MSG_ACCEPTED = "Connection from %s port %u\n";
const MSG_CLOSED = "Closed after %lu bytes\n";

fn failed(dl: *DosBase, sb: *SocketBase, what: [*:0]const u8) i32 {
    _ = Printf(dl, MSG_FAILED, .{ what, sb.Errno() });
    return dos.RETURN_ERROR;
}

fn textLength(text: [*:0]const u8) u32 {
    var length: u32 = 0;
    while (text[length] != 0) length += 1;
    return length;
}

/// `eth0` on QEMU's network, unless it is there already.
fn addInterface(sb: *SocketBase) bool {
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = bsd.IFA_Device, .data = @intFromPtr("networks/openeth.device") },
        .{ .tag = bsd.IFA_Address, .data = sb.Inet_Addr("10.0.2.15") },
        .{ .tag = bsd.IFA_Gateway, .data = sb.Inet_Addr("10.0.2.2") },
        .{},
    };
    return sb.AddInterfaceTagList("eth0", &tags) == 0 or sb.Errno() == bsd.EADDRINUSE;
}

/// Microseconds of system time, for the rate.
fn now(clock: *timer.TimeRequest) u64 {
    const timer_base: *TimerBase = @ptrCast(@alignCast(clock.node.device.?));
    var time: timer.TimeVal = .{};
    timer_base.GetSysTime(&time);
    return time.toMicros();
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [5]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{bsd.SOCKETNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(socket_lib);
    const sb: *SocketBase = @ptrCast(socket_lib);
    if (!addInterface(sb)) return failed(dl, sb, "AddInterfaceTagList");

    const listening = argv[arg_listen] != 0;
    const port: u16 = if (argv[arg_port] != 0) @truncate(@as(u32, @bitCast(@as(*const i32, @ptrFromInt(argv[arg_port])).*))) else if (listening) 2323 else 80;
    if (listening) return serve(dl, sb, port);

    var clock: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &clock.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&clock.node);

    const to_text: [*:0]const u8 = if (argv[arg_to] != 0) @ptrFromInt(argv[arg_to]) else "10.0.2.2";
    const hints: bsd.addrinfo = .{ .ai_socktype = bsd.SOCK_STREAM };
    var list: ?*bsd.addrinfo = null;
    if (sb.GetAddrInfo(to_text, null, &hints, &list) != 0) return failed(dl, sb, "GetAddrInfo");
    defer sb.FreeAddrInfo(list.?);
    const target = list.?;
    // The port into whichever sockaddr it is: both have it at offset 2.
    @as(*align(1) u16, @ptrCast(@as([*]u8, @ptrCast(target.ai_addr.?)) + 2)).* = bsd.htons(port);
    const socket = sb.Socket(target.ai_family, bsd.SOCK_STREAM, 0);
    if (socket < 0) return failed(dl, sb, "Socket");
    defer _ = sb.CloseSocket(socket);
    const started = now(&clock);
    if (sb.Connect(socket, target.ai_addr.?, target.ai_addrlen) < 0) return failed(dl, sb, "Connect");
    _ = Printf(dl, MSG_CONNECTED, .{ to_text, @as(u32, port) });

    var request: [256]u8 = undefined;
    var request_length: u32 = 0;
    if (argv[arg_get] != 0) {
        const path: [*:0]const u8 = @ptrFromInt(argv[arg_get]);
        for ([_][*:0]const u8{ "GET ", path, " HTTP/1.0\r\nHost: ", to_text, "\r\n\r\n" }) |part| {
            const length = textLength(part);
            if (request_length + length > request.len) break;
            @memcpy(request[request_length..][0..length], part[0..length]);
            request_length += length;
        }
    } else {
        const text: [*:0]const u8 = if (argv[arg_text] != 0) @ptrFromInt(argv[arg_text]) else "hello\n";
        request_length = @min(textLength(text), request.len);
        @memcpy(request[0..request_length], text[0..request_length]);
    }
    if (sb.Send(socket, &request, request_length, 0) < 0) return failed(dl, sb, "Send");

    var buffer: [2048]u8 = undefined;
    var total: u64 = 0;
    var first_line = false;
    while (true) {
        const got = sb.Recv(socket, &buffer, buffer.len - 1, 0);
        if (got < 0) return failed(dl, sb, "Recv");
        if (got == 0) break;
        if (!first_line) {
            var end: usize = 0;
            while (end < @as(usize, @intCast(got)) and buffer[end] != '\r' and buffer[end] != '\n') end += 1;
            buffer[end] = 0;
            _ = Printf(dl, MSG_FIRST, .{@as([*:0]const u8, @ptrCast(&buffer))});
            first_line = true;
        }
        total += @intCast(got);
    }
    const took_ms = @max((now(&clock) - started) / 1000, 1);
    _ = Printf(dl, MSG_DONE, .{ total, took_ms, total * 1000 / 1024 / took_ms });
    return dos.RETURN_OK;
}

/// One connection taken on `port`, and everything it sends sent back.
fn serve(dl: *DosBase, sb: *SocketBase, port: u16) i32 {
    const listener = sb.Socket(bsd.PF_INET6, bsd.SOCK_STREAM, 0);
    if (listener < 0) return failed(dl, sb, "Socket");
    defer _ = sb.CloseSocket(listener);
    const on: i32 = 1;
    _ = sb.SetSockOpt(listener, bsd.SOL_SOCKET, bsd.SO_REUSEADDR, &on, @sizeOf(i32));
    var here: bsd.sockaddr_in6 = .{ .sin6_port = bsd.htons(port) };
    if (sb.Bind(listener, here.anyConst(), @sizeOf(bsd.sockaddr_in6)) < 0) return failed(dl, sb, "Bind");
    if (sb.Listen(listener, 1) < 0) return failed(dl, sb, "Listen");
    _ = Printf(dl, MSG_LISTENING, .{@as(u32, port)});
    var peer: bsd.sockaddr_in6 = .{};
    var peer_length: u32 = @sizeOf(bsd.sockaddr_in6);
    const connection = sb.Accept(listener, peer.any(), &peer_length);
    if (connection < 0) return failed(dl, sb, "Accept");
    defer _ = sb.CloseSocket(connection);
    var peer_text: [bsd.INET6_ADDRSTRLEN]u8 = @splat(0);
    _ = sb.Inet_NtoP(bsd.AF_INET6, &peer.sin6_addr, &peer_text, peer_text.len);
    _ = Printf(dl, MSG_ACCEPTED, .{ @as([*:0]const u8, @ptrCast(&peer_text)), @as(u32, bsd.ntohs(peer.sin6_port)) });
    var buffer: [512]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const got = sb.Recv(connection, &buffer, buffer.len, 0);
        if (got < 0) return failed(dl, sb, "Recv");
        if (got == 0) break;
        total += @intCast(got);
        if (sb.Send(connection, &buffer, @intCast(got), 0) < 0) return failed(dl, sb, "Send");
    }
    _ = Printf(dl, MSG_CLOSED, .{total});
    return dos.RETURN_OK;
}
