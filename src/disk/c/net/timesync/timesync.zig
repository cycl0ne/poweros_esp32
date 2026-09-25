// SPDX-License-Identifier: MIT
//! TimeSync: the system's date and time set from a time server. Built
//! against the SDK only.
//!
//!   TimeSync SERVER,PORT/K/N,QUIET/S,TEST/S
//!
//! SERVER is a name or a dotted address; without it, the first time
//! server DHCP named for an interface, else the one in
//! `ENVARC:Sys/net/timeserver`, else pool.ntp.org. PORT is 123 unless
//! given. The time is set and printed, unless QUIET; TEST prints it and
//! sets nothing.
//!
//! **SNTP (RFC 4330).** One request goes out over UDP, and again after two
//! seconds, three times in all. An answer counts only from the server
//! asked, from the port asked, as a server's reply (mode 4) with a
//! stratum from 1 to 15, a clock that is set, and our request's transmit
//! time as its origin - a number made for the request, which no one who
//! did not see it can give back. The time is the server's transmit time
//! plus half the round trip, less the time the server held the request;
//! the round trip is measured on the E-clock, so the clock being wrong
//! does not change it.
//!
//! **Local time.** The system clock keeps local time. The zone is a POSIX
//! TZ rule in `ENVARC:Sys/timezone` (`CET-1CEST,M3.5.0,M10.5.0/3`,
//! zone.zig); with no file, the clock keeps UTC.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const timer = sdk.devices.timer;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const TimerBase = sdk.interface.timer.TimerBase;
const Printf = dos.stdio.Printf;
const zone = @import("zone.zig");

pub const COMMAND_NAME = "TimeSync";
const VERSION_STRING = "\x00$VER: TimeSync 1.0 (25.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "SERVER,PORT/K/N,QUIET/S,TEST/S";
const arg_server = 0;
const arg_port = 1;
const arg_quiet = 2;
const arg_test = 3;

/// The zone the system clock keeps, as a POSIX TZ rule.
const TIMEZONE_FILE = "ENVARC:Sys/timezone";
const server_default = "pool.ntp.org";
const port_default: u16 = 123;
const tries = 3;
const patience_secs = 2;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NOHOST = "%s: %s: no such host\n";
const MSG_FAILED = "%s: %s failed: errno %d\n";
const MSG_NOANSWER = "%s: no answer from %s\n";
const MSG_BADZONE = "%s: %s is no time zone rule; using UTC\n";
const MSG_TIME = "%s %s %s, from %s (stratum %u)";
const MSG_MOVED = ", the clock moved by %s%lu.%03u s\n";

/// 1 January 1900, where NTP counts from, to 1 January 1970; and 1970 to
/// 1 January 1978, where the system clock counts from.
const ntp_to_unix: u64 = 2_208_988_800;
const unix_to_system: i64 = 252_460_800;

const packet_bytes = 48;
const mode_client: u8 = 3;
const mode_server: u8 = 4;
const version: u8 = 4;
const leap_unset: u8 = 3;

/// An SNTP answer, as far as it is needed.
const Answer = struct {
    stratum: u8,
    /// The server's receive and transmit times, µs since 1900.
    received_us: u64,
    transmitted_us: u64,
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [4]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const quiet = argv[arg_quiet] != 0;
    const test_only = argv[arg_test] != 0;
    const port: u16 = if (argv[arg_port] != 0) @truncate(@as(u32, @bitCast(@as(*const i32, @ptrFromInt(argv[arg_port])).*))) else port_default;

    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, bsd.SOCKETNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(socket_lib);
    const sb: *SocketBase = @ptrCast(socket_lib);

    var clock: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &clock.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&clock.node);
    const timer_base: *TimerBase = @ptrCast(@alignCast(clock.node.device.?));

    var server_text: [64]u8 = @splat(0);
    const server: [*:0]const u8 = if (argv[arg_server] != 0) @ptrFromInt(argv[arg_server]) else chooseServer(dl, sb, &server_text);
    const entry = sb.GetHostByName(server) orelse {
        _ = Printf(dl, MSG_NOHOST, .{ COMMAND_NAME, server });
        return dos.RETURN_ERROR;
    };
    var to: bsd.sockaddr_in = .{ .sin_port = bsd.htons(port) };
    @memcpy(@as(*[4]u8, @ptrCast(&to.sin_addr.s_addr)), entry.h_addr_list.?[0].?[0..4]);
    var address_text: [16]u8 = @splat(0);
    copyText(&address_text, sb.Inet_NtoA(to.sin_addr.s_addr));

    const socket = sb.Socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    if (socket < 0) return failed(dl, sb, "Socket");
    defer _ = sb.CloseSocket(socket);

    var sent_at: u64 = 0;
    var round_trip: u64 = 0;
    const answer = ask(dl, sb, socket, &to, timer_base, &sent_at, &round_trip) orelse {
        if (sb.Errno() == bsd.EINTR) return dos.RETURN_WARN;
        _ = Printf(dl, MSG_NOANSWER, .{ COMMAND_NAME, @as([*:0]const u8, @ptrCast(&address_text)) });
        return dos.RETURN_ERROR;
    };

    // UTC now: the server's transmit time, half the round trip that was
    // not the server's own, and what has passed since the answer came.
    const held = answer.transmitted_us -| answer.received_us;
    const utc_us = answer.transmitted_us - ntp_to_unix * 1_000_000 + (round_trip -| held) / 2 + (eclock(timer_base) - (sent_at + round_trip));
    const utc_secs: i64 = @intCast(utc_us / 1_000_000);
    const rule = readZone(dl, quiet);
    const local_secs = utc_secs + rule.offsetAt(utc_secs);
    const new_time: timer.TimeVal = .{ .secs = @intCast(local_secs - unix_to_system), .micro = @intCast(utc_us % 1_000_000) };

    var old_time: timer.TimeVal = .{};
    timer_base.GetSysTime(&old_time);
    if (!test_only) {
        clock.node.command = timer.TR_SETSYSTIME;
        clock.time = new_time;
        _ = sys.DoIO(&clock.node);
    }
    if (quiet) return dos.RETURN_OK;

    var day: [dos.datetime.LEN_DATSTRING]u8 = @splat(0);
    var date: [dos.datetime.LEN_DATSTRING]u8 = @splat(0);
    var time: [dos.datetime.LEN_DATSTRING]u8 = @splat(0);
    var datetime: dos.datetime.DateTime = .{
        .stamp = .{
            .days = @intCast(new_time.secs / 86400),
            .minute = @intCast(new_time.secs % 86400 / 60),
            .tick = @intCast(new_time.secs % 60 * 50),
        },
        .str_day = @ptrCast(&day),
        .str_date = @ptrCast(&date),
        .str_time = @ptrCast(&time),
    };
    _ = dl.DateToStr(&datetime);
    _ = Printf(dl, MSG_TIME, .{ @as([*:0]const u8, @ptrCast(&day)), @as([*:0]const u8, @ptrCast(&date)), @as([*:0]const u8, @ptrCast(&time)), @as([*:0]const u8, @ptrCast(&address_text)), @as(u32, answer.stratum) });
    const new_us = new_time.toMicros();
    const old_us = old_time.toMicros();
    const moved = if (new_us >= old_us) new_us - old_us else old_us - new_us;
    const moved_ms = moved / 1000;
    const sign: [*:0]const u8 = if (new_us >= old_us) "+" else "-";
    if (test_only) {
        _ = Printf(dl, "; the clock is off by %s%lu.%03u s\n", .{ sign, moved_ms / 1000, @as(u32, @intCast(moved_ms % 1000)) });
    } else {
        _ = Printf(dl, MSG_MOVED, .{ sign, moved_ms / 1000, @as(u32, @intCast(moved_ms % 1000)) });
    }
    return dos.RETURN_OK;
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

/// The E-clock in microseconds.
fn eclock(timer_base: *TimerBase) u64 {
    var value: timer.EClockVal = .{};
    const rate = timer_base.ReadEClock(&value);
    const count = @as(u64, value.hi) << 32 | value.lo;
    return count / rate * 1_000_000 + count % rate * 1_000_000 / rate;
}

/// The server to ask when none is given: DHCP's for an interface, the
/// file's, or the pool's.
fn chooseServer(dl: *DosBase, sb: *SocketBase, text: *[64]u8) [*:0]const u8 {
    if (sb.ObtainInterfaceList()) |list| {
        defer sb.ReleaseInterfaceList(list);
        var it = list.iterator();
        while (it.next()) |node| {
            var address: u32 = 0;
            const tags = [_]TagItem{ .{ .tag = bsd.IFQ_TimeServer, .data = @intFromPtr(&address) }, .{} };
            if (sb.QueryInterfaceTagList(node.name.?, &tags) != 0 or address == 0) continue;
            copyText(text, sb.Inet_NtoA(address));
            return @ptrCast(text);
        }
    }
    if (firstLine(dl, bsd.TIMESERVER_FILE, text)) return @ptrCast(text);
    return server_default;
}

/// The first line of `name`, trimmed, into `text`: false when there is no
/// such file or the line is empty.
fn firstLine(dl: *DosBase, name: [*:0]const u8, text: []u8) bool {
    const file = dl.Open(name, dos.MODE_OLDFILE) orelse return false;
    defer _ = dl.Close(file);
    const got = dl.Read(file, text.ptr, @intCast(text.len - 1));
    if (got <= 0) return false;
    var end: usize = 0;
    while (end < @as(usize, @intCast(got)) and text[end] != '\n' and text[end] != '\r') end += 1;
    var start: usize = 0;
    while (start < end and (text[start] == ' ' or text[start] == '\t')) start += 1;
    while (end > start and (text[end - 1] == ' ' or text[end - 1] == '\t')) end -= 1;
    if (end == start) return false;
    if (start != 0) @memmove(text[0 .. end - start], text[start..end]);
    text[end - start] = 0;
    return true;
}

/// The zone in the timezone file; UTC without one, or with one that is no
/// rule.
fn readZone(dl: *DosBase, quiet: bool) zone.Zone {
    var text: [128]u8 = @splat(0);
    if (!firstLine(dl, TIMEZONE_FILE, &text)) return .{};
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return zone.parse(text[0..length]) orelse {
        if (!quiet) _ = Printf(dl, MSG_BADZONE, .{ COMMAND_NAME, TIMEZONE_FILE });
        return .{};
    };
}

fn get32(bytes: []const u8, at: usize) u32 {
    return @as(u32, bytes[at]) << 24 | @as(u32, bytes[at + 1]) << 16 | @as(u32, bytes[at + 2]) << 8 | bytes[at + 3];
}

/// An NTP timestamp at `at` in microseconds since 1900; seconds with the
/// top bit clear are past 2036, in the next era.
fn stampMicros(bytes: []const u8, at: usize) u64 {
    var seconds: u64 = get32(bytes, at);
    if (seconds & 0x8000_0000 == 0) seconds += 1 << 32;
    const fraction: u64 = get32(bytes, at + 4);
    return seconds * 1_000_000 + (fraction * 1_000_000 >> 32);
}

/// The request sent up to `tries` times and a good answer taken, with
/// when it was sent and how long the round trip took; null with Errno()
/// EINTR at Ctrl-C.
fn ask(dl: *DosBase, sb: *SocketBase, socket: i32, to: *bsd.sockaddr_in, timer_base: *TimerBase, sent_at: *u64, round_trip: *u64) ?Answer {
    var request: [packet_bytes]u8 = @splat(0);
    request[0] = version << 3 | mode_client;
    var reply: [packet_bytes + 16]u8 = undefined;
    for (0..tries) |_| {
        // The transmit time is a number of our own, given back as the
        // answer's origin: the E-clock and the task, not the date.
        const nonce = eclock(timer_base) ^ @as(u64, @intFromPtr(sb)) << 32;
        for (0..8) |index| request[40 + index] = @truncate(nonce >> @intCast(56 - index * 8));
        sent_at.* = eclock(timer_base);
        if (sb.SendTo(socket, &request, request.len, 0, to.anyConst(), @sizeOf(bsd.sockaddr_in)) < 0) {
            _ = failed(dl, sb, "SendTo");
            return null;
        }
        const deadline = sent_at.* + patience_secs * 1_000_000;
        while (true) {
            const now = eclock(timer_base);
            if (now >= deadline) break;
            var patience = timer.TimeVal.fromMicros(deadline - now);
            var read: bsd.fd_set = .{};
            read.set(socket);
            const ready = sb.WaitSelect(socket + 1, &read, null, null, &patience, null);
            if (ready < 0) return null;
            if (ready == 0) break;
            var from: bsd.sockaddr_in = .{};
            var from_length: u32 = @sizeOf(bsd.sockaddr_in);
            const got = sb.RecvFrom(socket, &reply, reply.len, 0, from.any(), &from_length);
            const arrived = eclock(timer_base);
            if (got < packet_bytes) continue;
            if (from.sin_addr.s_addr != to.sin_addr.s_addr or from.sin_port != to.sin_port) continue;
            if (reply[0] & 7 != mode_server or reply[0] >> 6 == leap_unset) continue;
            if (reply[1] == 0 or reply[1] > 15) continue;
            const origin_ours = for (reply[24..32], request[40..48]) |got_byte, sent_byte| {
                if (got_byte != sent_byte) break false;
            } else true;
            if (!origin_ours) continue;
            if (get32(&reply, 40) == 0) continue;
            round_trip.* = arrived - sent_at.*;
            return .{ .stratum = reply[1], .received_us = stampMicros(&reply, 32), .transmitted_us = stampMicros(&reply, 40) };
        }
    }
    return null;
}
