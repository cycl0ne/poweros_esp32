// SPDX-License-Identifier: MIT
//! Ping: ICMP or ICMPv6 echo requests to a host, and how long each
//! answer took. Built against the SDK only.
//!
//!   Ping HOST/A,COUNT/K/N,SIZE/K/N,INTERVAL/K/N,TIMEOUT/K/N,INET6=-6/S
//!
//! HOST is a name, a dotted IPv4 address, or an IPv6 address - a
//! link-local one followed by `%` and its interface, `fe80::2%eth0`. With
//! INET6 (or -6) a name is looked up as IPv6. COUNT requests are sent (4;
//! 0 goes on until Ctrl-C), each carrying SIZE bytes of data (56, at most
//! 1472 over IPv4, 1452 over IPv6) and INTERVAL seconds apart (1). Each
//! answer is printed with its size, its sender, its sequence number, its
//! time to live (IPv4) and the round trip in milliseconds; a request with
//! no answer in TIMEOUT seconds (1), and an error about one, are printed
//! too. At the end, or at Ctrl-C: how many went, how many came back, and
//! the shortest, mean and longest round trip.
//!
//! A request goes through a raw ICMP or ICMPv6 socket, which is given
//! every such message the machine receives - an ICMP one behind its IPv4
//! header, an ICMPv6 one without its header: an answer is ours when it
//! carries our identifier - taken from the task's address - and the
//! sequence number of the request out. The stack makes an ICMPv6
//! message's checksum. One request is out at a time, so its round trip is
//! measured from when it went, on the E-clock, which setting the date
//! does not move.

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

pub const COMMAND_NAME = "Ping";
const VERSION_STRING = "\x00$VER: Ping 1.1 (27.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "HOST/A,COUNT/K/N,SIZE/K/N,INTERVAL/K/N,TIMEOUT/K/N,INET6=-6/S";
const arg_host = 0;
const arg_count = 1;
const arg_size = 2;
const arg_interval = 3;
const arg_timeout = 4;
const arg_inet6 = 5;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NOHOST = "%s: %s: no such host\n";
const MSG_FAILED = "%s: %s failed: errno %d\n";
const MSG_START = "PING %s (%s): %u data bytes\n";
const MSG_REPLY = "%u bytes from %s: seq=%u ttl=%u time=%u.%03u ms\n";
const MSG_REPLY6 = "%u bytes from %s: seq=%u time=%u.%03u ms\n";
const MSG_NOIPV6 = "%s: %s: no IPv6 address\n";
const MSG_LOST = "No answer to seq=%u\n";
const MSG_ERROR = "From %s: %s, seq=%u\n";
const MSG_SUMMARY = "--- %s ---\n%u sent, %u received, %u%% lost\n";
const MSG_TIMES = "round trip min/avg/max = %u.%03u/%u.%03u/%u.%03u ms\n";

const echo_reply: u8 = 0;
const unreachable_type: u8 = 3;
const echo_request: u8 = 8;
const time_exceeded: u8 = 11;

/// ICMPv6's.
const unreachable6: u8 = 1;
const too_big6: u8 = 2;
const time_exceeded6: u8 = 3;
const echo_request6: u8 = 128;
const echo_reply6: u8 = 129;

/// The ICMP header.
const header_bytes = 8;
const size_default = 56;
/// What fits in one Ethernet frame unfragmented.
const size_most = 1472;
const size_most6 = 1452;
/// A request, or an answer with its IP header.
const buffer_bytes = 60 + header_bytes + size_most;

/// The round trips so far, in microseconds.
const Tally = struct {
    sent: u32 = 0,
    received: u32 = 0,
    least: u32 = 0xFFFF_FFFF,
    most: u32 = 0,
    total: u64 = 0,

    fn add(tally: *Tally, micros: u32) void {
        tally.received += 1;
        tally.least = @min(tally.least, micros);
        tally.most = @max(tally.most, micros);
        tally.total += micros;
    }
};

/// The E-clock, as the device keeps it: a count and its rate.
const Clock = struct {
    timer_base: *TimerBase,

    fn now(clock: Clock) u64 {
        var value: timer.EClockVal = .{};
        const rate = clock.timer_base.ReadEClock(&value);
        const count = @as(u64, value.hi) << 32 | value.lo;
        return count / rate * 1_000_000 + count % rate * 1_000_000 / rate;
    }
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [6]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const host: [*:0]const u8 = @ptrFromInt(argv[arg_host]);
    const count = number(argv[arg_count], 4);
    var size = @min(number(argv[arg_size], size_default), size_most);
    const interval_us = @as(u64, @max(number(argv[arg_interval], 1), 1)) * 1_000_000;
    const timeout_us = @as(u64, @max(number(argv[arg_timeout], 1), 1)) * 1_000_000;

    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, bsd.SOCKETNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(socket_lib);
    const sb: *SocketBase = @ptrCast(socket_lib);

    var clock_request: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &clock_request.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&clock_request.node);
    const clock: Clock = .{ .timer_base = @ptrCast(@alignCast(clock_request.node.device.?)) };

    var target: Target = .{};
    if (!target.find(dl, sb, host, argv[arg_inet6] != 0)) return dos.RETURN_ERROR;
    if (target.six) size = @min(size, size_most6);

    const memory = sys.AllocVec(buffer_bytes, exec.MEMF_ANY) orelse return dos.RETURN_FAIL;
    defer sys.FreeVec(memory);
    const buffer = @as([*]u8, @ptrCast(memory))[0..buffer_bytes];

    const raw = if (target.six) sb.Socket(bsd.PF_INET6, bsd.SOCK_RAW, bsd.IPPROTO_ICMPV6) else sb.Socket(bsd.PF_INET, bsd.SOCK_RAW, bsd.IPPROTO_ICMP);
    if (raw < 0) return failed(dl, sb, "Socket");
    defer _ = sb.CloseSocket(raw);

    _ = Printf(dl, MSG_START, .{ host, target.textZ(), size });
    const identifier: u16 = @truncate(@intFromPtr(sys.FindTask(null)) >> 2);
    var tally: Tally = .{};
    var sequence: u32 = 1;
    var result: i32 = dos.RETURN_OK;
    while (count == 0 or sequence <= count) : (sequence += 1) {
        const sent_at = clock.now();
        if (!send(sb, raw, buffer, &target, identifier, @truncate(sequence), size)) {
            result = failed(dl, sb, "SendTo");
            break;
        }
        tally.sent += 1;
        const outcome = if (target.six)
            answer6(dl, sb, raw, buffer, clock, identifier, @truncate(sequence), sent_at, timeout_us, &tally)
        else
            answer(dl, sb, raw, buffer, clock, identifier, @truncate(sequence), sent_at, timeout_us, &tally);
        if (outcome == .stopped) break;
        if (outcome == .failed) {
            result = dos.RETURN_ERROR;
            break;
        }
        if (outcome == .lost) _ = Printf(dl, MSG_LOST, .{sequence});
        if (count != 0 and sequence == count) break;
        // The rest of the interval; late answers are let go.
        if (!pause(sb, raw, buffer, clock, sent_at + interval_us)) break;
    }

    const lost = tally.sent - tally.received;
    const percent = if (tally.sent == 0) 0 else lost * 100 / tally.sent;
    _ = Printf(dl, MSG_SUMMARY, .{ host, tally.sent, tally.received, percent });
    if (tally.received != 0) {
        const mean: u32 = @intCast(tally.total / tally.received);
        _ = Printf(dl, MSG_TIMES, .{
            tally.least / 1000, tally.least % 1000,
            mean / 1000,        mean % 1000,
            tally.most / 1000,  tally.most % 1000,
        });
    }
    if (result != dos.RETURN_OK) return result;
    return if (tally.received == 0) dos.RETURN_WARN else dos.RETURN_OK;
}

/// Where the requests go: an IPv4 or an IPv6 address, and it as text.
const Target = struct {
    six: bool = false,
    to4: bsd.sockaddr_in = .{},
    to6: bsd.sockaddr_in6 = .{},
    text: [bsd.INET6_ADDRSTRLEN + bsd.IFNAMSIZ]u8 = @splat(0),

    fn textZ(target: *const Target) [*:0]const u8 {
        return @ptrCast(&target.text);
    }

    /// `host` as an address: IPv6 text with its zone, a dotted IPv4
    /// address, or a name. False, said, when it is none.
    fn find(target: *Target, dl: *DosBase, sb: *SocketBase, host: [*:0]const u8, six: bool) bool {
        var literal: [bsd.INET6_ADDRSTRLEN]u8 = @splat(0);
        var at: usize = 0;
        while (host[at] != 0 and host[at] != '%' and at + 1 < literal.len) : (at += 1) literal[at] = host[at];
        const zone: ?[*:0]const u8 = if (host[at] == '%') host + at + 1 else null;
        if (sb.Inet_PtoN(bsd.AF_INET6, @ptrCast(&literal), &target.to6.sin6_addr) == 1) {
            target.six = true;
            if (zone) |name| {
                target.to6.sin6_scope_id = sb.If_NameToIndex(name);
                if (target.to6.sin6_scope_id == 0) {
                    _ = Printf(dl, MSG_NOHOST, .{ COMMAND_NAME, host });
                    return false;
                }
            }
            _ = sb.Inet_NtoP(bsd.AF_INET6, &target.to6.sin6_addr, &target.text, bsd.INET6_ADDRSTRLEN);
            if (zone) |name| {
                var end: usize = 0;
                while (target.text[end] != 0) end += 1;
                target.text[end] = '%';
                copyText(target.text[end + 1 ..], name);
            }
            return true;
        }
        if (six) {
            const hints: bsd.addrinfo = .{ .ai_family = bsd.AF_INET6, .ai_socktype = bsd.SOCK_DGRAM };
            var list: ?*bsd.addrinfo = null;
            if (sb.GetAddrInfo(host, null, &hints, &list) != 0) {
                _ = Printf(dl, MSG_NOIPV6, .{ COMMAND_NAME, host });
                return false;
            }
            defer sb.FreeAddrInfo(list.?);
            target.six = true;
            target.to6 = @as(*const bsd.sockaddr_in6, @ptrCast(@alignCast(list.?.ai_addr.?))).*;
            target.to6.sin6_port = 0;
            _ = sb.Inet_NtoP(bsd.AF_INET6, &target.to6.sin6_addr, &target.text, bsd.INET6_ADDRSTRLEN);
            return true;
        }
        const entry = sb.GetHostByName(host) orelse {
            _ = Printf(dl, MSG_NOHOST, .{ COMMAND_NAME, host });
            return false;
        };
        @memcpy(@as(*[4]u8, @ptrCast(&target.to4.sin_addr.s_addr)), entry.h_addr_list.?[0].?[0..4]);
        copyText(&target.text, sb.Inet_NtoA(target.to4.sin_addr.s_addr));
        return true;
    }
};

fn number(arg: usize, default: u32) u32 {
    if (arg == 0) return default;
    const value: *const i32 = @ptrFromInt(arg);
    return if (value.* < 0) default else @intCast(value.*);
}

fn copyText(into: []u8, text: [*:0]const u8) void {
    var at: usize = 0;
    while (at + 1 < into.len and text[at] != 0) : (at += 1) into[at] = text[at];
    into[at] = 0;
}

fn failed(dl: *DosBase, sb: *SocketBase, what: [*:0]const u8) i32 {
    _ = Printf(dl, MSG_FAILED, .{ COMMAND_NAME, what, sb.Errno() });
    return dos.RETURN_ERROR;
}

fn put16(bytes: []u8, at: usize, value: u16) void {
    bytes[at] = @truncate(value >> 8);
    bytes[at + 1] = @truncate(value);
}

fn get16(bytes: []const u8, at: usize) u16 {
    return @as(u16, bytes[at]) << 8 | bytes[at + 1];
}

/// The Internet checksum of `bytes`.
fn checksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    var at: usize = 0;
    while (at + 1 < bytes.len) : (at += 2) sum += get16(bytes, at);
    if (at < bytes.len) sum += @as(u32, bytes[at]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}

/// An echo request with `size` bytes of data, built in `request`; an
/// ICMPv6 one's checksum is the stack's to make.
fn send(sb: *SocketBase, raw: i32, request: []u8, target: *const Target, identifier: u16, sequence: u16, size: u32) bool {
    const length = header_bytes + size;
    request[0] = if (target.six) echo_request6 else echo_request;
    request[1] = 0;
    put16(request, 2, 0);
    put16(request, 4, identifier);
    put16(request, 6, sequence);
    for (header_bytes..length) |at| request[at] = @truncate(at);
    if (target.six) return sb.SendTo(raw, request.ptr, length, 0, target.to6.anyConst(), @sizeOf(bsd.sockaddr_in6)) >= 0;
    put16(request, 2, checksum(request[0..length]));
    return sb.SendTo(raw, request.ptr, length, 0, target.to4.anyConst(), @sizeOf(bsd.sockaddr_in)) >= 0;
}

const Outcome = enum { answered, lost, stopped, failed };

/// The answer to `sequence`, sent at `sent_at`, or an ICMP error about
/// it, waited for `timeout_us`.
fn answer(dl: *DosBase, sb: *SocketBase, raw: i32, buffer: []u8, clock: Clock, identifier: u16, sequence: u16, sent_at: u64, timeout_us: u64, tally: *Tally) Outcome {
    const deadline = sent_at + timeout_us;
    while (true) {
        const now = clock.now();
        if (now >= deadline) return .lost;
        var patience = timer.TimeVal.fromMicros(deadline - now);
        var read: bsd.fd_set = .{};
        read.set(raw);
        const ready = sb.WaitSelect(raw + 1, &read, null, null, &patience, null);
        if (ready < 0) {
            if (sb.Errno() == bsd.EINTR) return .stopped;
            _ = failed(dl, sb, "WaitSelect");
            return .failed;
        }
        if (ready == 0) continue;
        var from: bsd.sockaddr_in = .{};
        var from_length: u32 = @sizeOf(bsd.sockaddr_in);
        const got = sb.RecvFrom(raw, buffer.ptr, @intCast(buffer.len), 0, from.any(), &from_length);
        const arrived = clock.now();
        if (got < 20) continue;
        const packet = buffer[0..@intCast(got)];
        const header_length = @as(usize, packet[0] & 0xF) * 4;
        if (packet.len < header_length + header_bytes) continue;
        const icmp = packet[header_length..];
        switch (icmp[0]) {
            echo_reply => {
                if (get16(icmp, 4) != identifier or get16(icmp, 6) != sequence) continue;
                const micros: u32 = @intCast(@min(arrived -| sent_at, 0xFFFF_FFFF));
                tally.add(micros);
                _ = Printf(dl, MSG_REPLY, .{ @as(u32, @intCast(icmp.len)), sb.Inet_NtoA(from.sin_addr.s_addr), @as(u32, sequence), @as(u32, packet[8]), micros / 1000, micros % 1000 });
                return .answered;
            },
            unreachable_type, time_exceeded => {
                // The error quotes the IP header and 8 bytes of our request.
                const quoted = icmp[header_bytes..];
                if (quoted.len < 20) continue;
                const quoted_length = @as(usize, quoted[0] & 0xF) * 4;
                if (quoted.len < quoted_length + header_bytes) continue;
                const request = quoted[quoted_length..];
                if (request[0] != echo_request or get16(request, 4) != identifier or get16(request, 6) != sequence) continue;
                const what: [*:0]const u8 = if (icmp[0] == time_exceeded) "time to live exceeded" else switch (icmp[1]) {
                    0 => "net unreachable",
                    1 => "host unreachable",
                    3 => "port unreachable",
                    else => "destination unreachable",
                };
                _ = Printf(dl, MSG_ERROR, .{ sb.Inet_NtoA(from.sin_addr.s_addr), what, @as(u32, sequence) });
                return .lost;
            },
            else => continue,
        }
    }
}

/// The answer to `sequence` over IPv6, as `answer` waits for it: the
/// messages come without their IPv6 header, and an error quotes the IPv6
/// header of our request, then the request.
fn answer6(dl: *DosBase, sb: *SocketBase, raw: i32, buffer: []u8, clock: Clock, identifier: u16, sequence: u16, sent_at: u64, timeout_us: u64, tally: *Tally) Outcome {
    const deadline = sent_at + timeout_us;
    while (true) {
        const now = clock.now();
        if (now >= deadline) return .lost;
        var patience = timer.TimeVal.fromMicros(deadline - now);
        var read: bsd.fd_set = .{};
        read.set(raw);
        const ready = sb.WaitSelect(raw + 1, &read, null, null, &patience, null);
        if (ready < 0) {
            if (sb.Errno() == bsd.EINTR) return .stopped;
            _ = failed(dl, sb, "WaitSelect");
            return .failed;
        }
        if (ready == 0) continue;
        var from: bsd.sockaddr_in6 = .{};
        var from_length: u32 = @sizeOf(bsd.sockaddr_in6);
        const got = sb.RecvFrom(raw, buffer.ptr, @intCast(buffer.len), 0, from.any(), &from_length);
        const arrived = clock.now();
        if (got < header_bytes) continue;
        const icmp = buffer[0..@intCast(got)];
        var from_text: [bsd.INET6_ADDRSTRLEN]u8 = @splat(0);
        _ = sb.Inet_NtoP(bsd.AF_INET6, &from.sin6_addr, &from_text, from_text.len);
        const sender: [*:0]const u8 = @ptrCast(&from_text);
        switch (icmp[0]) {
            echo_reply6 => {
                if (get16(icmp, 4) != identifier or get16(icmp, 6) != sequence) continue;
                const micros: u32 = @intCast(@min(arrived -| sent_at, 0xFFFF_FFFF));
                tally.add(micros);
                _ = Printf(dl, MSG_REPLY6, .{ @as(u32, @intCast(icmp.len)), sender, @as(u32, sequence), micros / 1000, micros % 1000 });
                return .answered;
            },
            unreachable6, too_big6, time_exceeded6 => {
                const quoted = icmp[header_bytes..];
                if (quoted.len < 40 + header_bytes or quoted[6] != 58) continue;
                const request = quoted[40..];
                if (request[0] != echo_request6 or get16(request, 4) != identifier or get16(request, 6) != sequence) continue;
                const what: [*:0]const u8 = switch (icmp[0]) {
                    time_exceeded6 => "hop limit exceeded",
                    too_big6 => "packet too big",
                    else => switch (icmp[1]) {
                        0 => "no route",
                        1 => "administratively prohibited",
                        3 => "address unreachable",
                        4 => "port unreachable",
                        else => "destination unreachable",
                    },
                };
                _ = Printf(dl, MSG_ERROR, .{ sender, what, @as(u32, sequence) });
                return .lost;
            },
            else => continue,
        }
    }
}

/// Until `deadline`, whatever comes read and let go: false at Ctrl-C.
fn pause(sb: *SocketBase, raw: i32, buffer: []u8, clock: Clock, deadline: u64) bool {
    while (true) {
        const now = clock.now();
        if (now >= deadline) return true;
        var patience = timer.TimeVal.fromMicros(deadline - now);
        var read: bsd.fd_set = .{};
        read.set(raw);
        const ready = sb.WaitSelect(raw + 1, &read, null, null, &patience, null);
        if (ready < 0) return sb.Errno() != bsd.EINTR;
        if (ready > 0) _ = sb.RecvFrom(raw, buffer.ptr, @intCast(buffer.len), 0, null, null);
    }
}
