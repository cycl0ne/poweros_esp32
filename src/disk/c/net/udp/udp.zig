// SPDX-License-Identifier: MIT
//! Udp: a datagram sent, and its echo waited for, through
//! bsdsocket.library. Built against the SDK only.
//!
//!   Udp TO/K,PORT/K/N,TEXT/K,DEVICE/K,ADDRESS/K,GATEWAY/K,REMOVE/S,PING/S
//!
//! It sends TEXT ("hello") to TO:PORT (127.0.0.1:7) - TO an IPv4 or an
//! IPv6 address - and prints what comes back within two seconds, and
//! from where. Every datagram socket is an AF_INET6 one, an IPv4 peer its
//! mapped address. When TO is a loopback
//! address, the program is its own echo as well: a second socket bound to
//! PORT takes the datagram, WaitSelect wakes it, and it sends the text
//! back - both ends in one program, over `lo0`, with no network device.
//!
//! Any other TO goes out on the network: the interface `eth0` is added
//! first, on DEVICE (networks/openeth.device) with ADDRESS (10.0.2.15/24)
//! and GATEWAY (10.0.2.2) - the addresses QEMU's user network gives - unless
//! it is there already. REMOVE takes `eth0` down again and sends nothing.
//! PING sends an ICMP echo request with TEXT to an IPv4 TO through a raw
//! socket instead, and prints the echo that comes back.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Udp";
const VERSION_STRING = "\x00$VER: Udp 1.2 (03.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TO/K,PORT/K/N,TEXT/K,DEVICE/K,ADDRESS/K,GATEWAY/K,REMOVE/S,PING/S";
const arg_to = 0;
const arg_port = 1;
const arg_text = 2;
const arg_device = 3;
const arg_address = 4;
const arg_gateway = 5;
const arg_remove = 6;
const arg_ping = 7;

const MSG_NOLIBRARY = "Can't open %s\n";
const MSG_BADADDRESS = "%s is not an address\n";
const MSG_PINGV4 = "PING is for IPv4; C:net/Ping -6 pings %s\n";
const MSG_FAILED = "%s failed: %s (errno %d)\n";
const MSG_SENT = "Sent %d bytes to %s port %u\n";
const MSG_ECHOED = "Echoed %d bytes from port %u\n";
const MSG_ANSWER = "Answer from %s port %u: %s\n";
const MSG_NOANSWER = "No answer in two seconds\n";
const MSG_BREAK = "***Break\n";
const MSG_INTERFACE = "eth0 is %s on %s\n";
const MSG_REMOVED = "eth0 is gone\n";
const MSG_PINGED = "Echo request to %s, %d bytes\n";
const MSG_ECHO = "Echo reply from %s: %s\n";

/// How long the answer may take.
const patience_secs = 2;

/// An ICMP echo request with `text` to `to`, and the reply waited for.
fn ping(dl: *DosBase, sb: *SocketBase, to: *bsd.sockaddr_in, to_text: [*:0]const u8, text: [*:0]const u8, text_length: u32) i32 {
    const raw = sb.Socket(bsd.PF_INET, bsd.SOCK_RAW, bsd.IPPROTO_ICMP);
    if (raw < 0) return failed(dl, sb, "Socket");
    defer _ = sb.CloseSocket(raw);
    var request: [8 + 64]u8 = @splat(0);
    const length = 8 + @min(text_length, 64);
    request[0] = 8; // echo request
    request[4] = 0x50; // identifier
    request[5] = 0x4F;
    request[7] = 1; // sequence
    for (0..length - 8) |at| request[8 + at] = text[at];
    var sum: u32 = 0;
    var at: usize = 0;
    while (at < length) : (at += 2) sum += @as(u32, request[at]) << 8 | (if (at + 1 < length) request[at + 1] else 0);
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    const checksum = ~@as(u16, @truncate(sum));
    request[2] = @truncate(checksum >> 8);
    request[3] = @truncate(checksum);
    const sent = sb.SendTo(raw, &request, length, 0, to.anyConst(), @sizeOf(bsd.sockaddr_in));
    if (sent < 0) return failed(dl, sb, "SendTo");
    _ = Printf(dl, MSG_PINGED, .{ to_text, sent });
    var patience: bsd.timeval = .{ .secs = patience_secs };
    var buffer: [128]u8 = undefined;
    while (true) {
        var read: bsd.fd_set = .{};
        read.set(raw);
        const ready = sb.WaitSelect(raw + 1, &read, null, null, &patience, null);
        if (ready < 0) return failed(dl, sb, "WaitSelect");
        if (ready == 0) {
            _ = Printf(dl, MSG_NOANSWER, .{});
            return dos.RETURN_WARN;
        }
        var from: bsd.sockaddr_in = .{};
        var from_length: u32 = @sizeOf(bsd.sockaddr_in);
        const got = sb.RecvFrom(raw, &buffer, buffer.len - 1, 0, from.any(), &from_length);
        if (got < 28) continue;
        const header_length = @as(usize, buffer[0] & 0xF) * 4;
        // Every ICMP message comes to a raw socket: only our echo's reply counts.
        if (buffer[header_length] != 0 or buffer[header_length + 4] != 0x50 or buffer[header_length + 5] != 0x4F) continue;
        buffer[@intCast(got)] = 0;
        _ = Printf(dl, MSG_ECHO, .{ sb.Inet_NtoA(from.sin_addr.s_addr), @as([*:0]const u8, @ptrCast(&buffer[header_length + 8])) });
        return dos.RETURN_OK;
    }
}

fn argText(argv: []const usize, index: usize, default: [*:0]const u8) [*:0]const u8 {
    return if (argv[index] != 0) @ptrFromInt(argv[index]) else default;
}

/// `eth0` on the network device: 1 when it was added, 0 when it was there
/// already, -1 when it could not be.
fn addInterface(sb: *SocketBase, argv: []const usize) i32 {
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = bsd.IFA_Device, .data = @intFromPtr(argText(argv, arg_device, "networks/openeth.device")) },
        .{ .tag = bsd.IFA_Address, .data = sb.Inet_Addr(argText(argv, arg_address, "10.0.2.15")) },
        .{ .tag = bsd.IFA_Gateway, .data = sb.Inet_Addr(argText(argv, arg_gateway, "10.0.2.2")) },
        .{},
    };
    if (sb.AddInterfaceTagList("eth0", &tags) == 0) return 1;
    return if (sb.Errno() == bsd.EADDRINUSE) 0 else -1;
}

fn failed(dl: *DosBase, sb: *SocketBase, what: [*:0]const u8) i32 {
    _ = Printf(dl, MSG_FAILED, .{ what, bsd.errnoText(sb, sb.Errno()), sb.Errno() });
    return dos.RETURN_ERROR;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [8]usize = @splat(0);
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

    if (argv[arg_remove] != 0) {
        if (sb.RemoveInterface("eth0") < 0) return failed(dl, sb, "RemoveInterface");
        _ = Printf(dl, MSG_REMOVED, .{});
        return dos.RETURN_OK;
    }

    const to_text: [*:0]const u8 = if (argv[arg_to] != 0) @ptrFromInt(argv[arg_to]) else "127.0.0.1";
    const port: u16 = if (argv[arg_port] != 0) @truncate(@as(u32, @bitCast(@as(*const i32, @ptrFromInt(argv[arg_port])).*))) else 7;
    const text: [*:0]const u8 = if (argv[arg_text] != 0) @ptrFromInt(argv[arg_text]) else "hello";
    var text_length: u32 = 0;
    while (text[text_length] != 0) text_length += 1;

    // An IPv4 address mapped, or IPv6 as it is.
    var to6: bsd.sockaddr_in6 = .{ .sin6_port = bsd.htons(port) };
    const address = sb.Inet_Addr(to_text);
    const is_v4 = address != bsd.INADDR_NONE;
    if (is_v4) {
        to6.sin6_addr.s6_addr[10] = 0xff;
        to6.sin6_addr.s6_addr[11] = 0xff;
        to6.sin6_addr.s6_addr[12..16].* = @bitCast(address);
    } else if (sb.Inet_PtoN(bsd.AF_INET6, to_text, &to6.sin6_addr) != 1) {
        _ = Printf(dl, MSG_BADADDRESS, .{to_text});
        return dos.RETURN_ERROR;
    }
    const loopback = if (is_v4) bsd.ntohl(address) >> 24 == 127 else for (to6.sin6_addr.s6_addr, bsd.in6addr_loopback.s6_addr) |a, b| {
        if (a != b) break false;
    } else true;
    if (!loopback) {
        const outcome = addInterface(sb, &argv);
        if (outcome < 0) return failed(dl, sb, "AddInterfaceTagList");
        if (outcome > 0) _ = Printf(dl, MSG_INTERFACE, .{ argText(&argv, arg_address, "10.0.2.15"), argText(&argv, arg_device, "networks/openeth.device") });
    }

    if (argv[arg_ping] != 0) {
        if (!is_v4) {
            _ = Printf(dl, MSG_PINGV4, .{to_text});
            return dos.RETURN_ERROR;
        }
        var to: bsd.sockaddr_in = .{ .sin_port = bsd.htons(port), .sin_addr = .{ .s_addr = address } };
        return ping(dl, sb, &to, to_text, text, text_length);
    }

    // The echo, when the answer is to come from this machine.
    var echo: i32 = -1;
    if (loopback) {
        echo = sb.Socket(bsd.PF_INET6, bsd.SOCK_DGRAM, 0);
        if (echo < 0) return failed(dl, sb, "Socket");
        if (sb.Bind(echo, to6.anyConst(), @sizeOf(bsd.sockaddr_in6)) < 0) return failed(dl, sb, "Bind");
    }
    defer if (echo >= 0) {
        _ = sb.CloseSocket(echo);
    };

    const socket = sb.Socket(bsd.PF_INET6, bsd.SOCK_DGRAM, 0);
    if (socket < 0) return failed(dl, sb, "Socket");
    defer _ = sb.CloseSocket(socket);
    const sent = sb.SendTo(socket, text, text_length, 0, to6.anyConst(), @sizeOf(bsd.sockaddr_in6));
    if (sent < 0) return failed(dl, sb, "SendTo");
    _ = Printf(dl, MSG_SENT, .{ sent, to_text, @as(u32, port) });

    // A Ctrl-C from before this command started is not a request to stop it.
    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C);
    var buffer: [512]u8 = undefined;
    var patience: bsd.timeval = .{ .secs = patience_secs };
    while (true) {
        var read: bsd.fd_set = .{};
        read.set(socket);
        if (echo >= 0) read.set(echo);
        const highest = if (echo > socket) echo else socket;
        const ready = sb.WaitSelect(highest + 1, &read, null, null, &patience, null);
        if (ready < 0) {
            if (sb.Errno() == bsd.EINTR) {
                _ = Printf(dl, MSG_BREAK, .{});
                return dos.RETURN_WARN;
            }
            return failed(dl, sb, "WaitSelect");
        }
        if (ready == 0) {
            _ = Printf(dl, MSG_NOANSWER, .{});
            return dos.RETURN_WARN;
        }
        if (echo >= 0 and read.isSet(echo)) {
            var from: bsd.sockaddr_in6 = .{};
            var from_length: u32 = @sizeOf(bsd.sockaddr_in6);
            const got = sb.RecvFrom(echo, &buffer, buffer.len, 0, from.any(), &from_length);
            if (got < 0) return failed(dl, sb, "RecvFrom");
            _ = Printf(dl, MSG_ECHOED, .{ got, @as(u32, bsd.ntohs(from.sin6_port)) });
            if (sb.SendTo(echo, &buffer, @intCast(got), 0, from.anyConst(), from_length) < 0) return failed(dl, sb, "SendTo");
        }
        if (read.isSet(socket)) {
            var from: bsd.sockaddr_in6 = .{};
            var from_length: u32 = @sizeOf(bsd.sockaddr_in6);
            const got = sb.RecvFrom(socket, &buffer, buffer.len - 1, 0, from.any(), &from_length);
            if (got < 0) return failed(dl, sb, "RecvFrom");
            buffer[@intCast(got)] = 0;
            var from_text: [bsd.INET6_ADDRSTRLEN]u8 = @splat(0);
            _ = sb.Inet_NtoP(bsd.AF_INET6, &from.sin6_addr, &from_text, from_text.len);
            _ = Printf(dl, MSG_ANSWER, .{ @as([*:0]const u8, @ptrCast(&from_text)), @as(u32, bsd.ntohs(from.sin6_port)), @as([*:0]const u8, @ptrCast(&buffer)) });
            return dos.RETURN_OK;
        }
    }
}
