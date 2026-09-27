// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Thomas Dye
//! The icmp category, tests 132 to 136: echo requests on a raw ICMP
//! socket - to 127.0.0.1; with the host helper, to its machine, with a
//! payload of 1024 bytes, and five in a row; and to 192.0.2.1, where
//! nothing answers. A request carries the test pattern, and an answer is
//! ours when its identifier and sequence number are; its IP header comes
//! with it and is stepped over.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _run = @import("run.zig");
const Run = _run.Run;

const echo_request = 8;
const echo_reply = 0;
/// The identifier the requests carry.
const identifier: u16 = 0xBD51;
/// The ICMP header: type, code, checksum, identifier, sequence.
const header_bytes = 8;
/// How long an answer is waited for.
const timeout_ms: u32 = 3000;

/// The Internet checksum of `bytes`.
fn checksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    var at: usize = 0;
    while (at + 1 < bytes.len) : (at += 2) sum += @as(u32, bytes[at]) << 8 | bytes[at + 1];
    if (at < bytes.len) sum += @as(u32, bytes[at]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

fn put16(bytes: []u8, value: u16) void {
    bytes[0] = @truncate(value >> 8);
    bytes[1] = @truncate(value);
}

fn get16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) << 8 | bytes[1];
}

/// An echo request to `target` (network order) with `payload` bytes:
/// the round trip in microseconds, 0 when nothing answered in time, -1
/// when the request could not go.
fn ping(run: *Run, target: u32, payload: u32, sequence: u16) i32 {
    const sb = run.sb;
    const raw = sb.Socket(bsd.AF_INET, bsd.SOCK_RAW, bsd.IPPROTO_ICMP);
    if (raw < 0) return -1;
    defer run.close(raw);

    const request = run.buffers.icmp_send[0 .. header_bytes + payload];
    @memset(request, 0);
    request[0] = echo_request;
    put16(request[4..6], identifier);
    put16(request[6..8], sequence);
    _run.fillPattern(request[header_bytes..], sequence);
    put16(request[2..4], checksum(request));

    const to: bsd.sockaddr_in = .{ .sin_addr = .{ .s_addr = target } };
    if (sb.SendTo(raw, request.ptr, @intCast(request.len), 0, to.anyConst(), @sizeOf(bsd.sockaddr_in)) < 0) return -1;

    const started = run.now();
    var left = timeout_ms;
    while (left > 0) {
        if (run.waitReadable(raw, left / 1000, left % 1000 * 1000) <= 0) break;
        const answer = &run.buffers.icmp_receive;
        const got = sb.Recv(raw, answer, answer.len, 0);
        if (got <= 0) break;
        const packet = answer[0..@intCast(got)];
        const header_length = @as(usize, packet[0] & 0x0F) * 4;
        if (packet.len >= header_length + header_bytes) {
            const icmp = packet[header_length..];
            if (icmp[0] == echo_reply and get16(icmp[4..6]) == identifier and get16(icmp[6..8]) == sequence) {
                const round_trip: u64 = run.now() - started;
                if (icmp.len >= header_bytes + payload) {
                    const mismatch = _run.checkPattern(icmp[header_bytes..][0..payload], sequence);
                    if (mismatch != 0) run.tap.diag("  ICMP payload mismatch at offset %u", .{mismatch});
                }
                return @intCast(@max(round_trip, 1));
            }
        }
        const spent = run.msSince(started);
        left = if (spent >= timeout_ms) 0 else timeout_ms - spent;
    }
    return 0;
}

pub fn tests(run: *Run) void {
    const raw = run.sb.Socket(bsd.AF_INET, bsd.SOCK_RAW, bsd.IPPROTO_ICMP);
    if (raw < 0) {
        for (0..5) |_| {
            run.tap.skip("SOCK_RAW/ICMP not supported");
            if (run.interrupted()) return;
        }
        return;
    }
    run.close(raw);

    // 132. 127.0.0.1.
    var round_trip = ping(run, bsd.htonl(bsd.INADDR_LOOPBACK), 56, 1);
    run.tap.ok(round_trip > 0, "ICMP echo: loopback 127.0.0.1 [RFC 792]");
    if (round_trip > 0) {
        run.tap.diag("  RTT=%d.%03dms", .{ @divTrunc(round_trip, 1000), @rem(round_trip, 1000) });
        run.tap.note("Loopback RTT: %d.%03dms", .{ @divTrunc(round_trip, 1000), @rem(round_trip, 1000) });
    } else {
        run.tap.diag("  result=%d", .{round_trip});
    }
    if (run.interrupted()) return;

    if (!run.helper.connected) {
        for (0..3) |_| {
            run.tap.skip("host helper not connected");
            if (run.interrupted()) return;
        }
    } else {
        const target = run.helper.address;

        // 133. The helper's machine.
        round_trip = ping(run, target, 56, 2);
        run.tap.ok(round_trip > 0, "ICMP echo: network host [RFC 792]");
        if (round_trip > 0) {
            run.tap.diag("  RTT=%d.%03dms, target=%s", .{ @divTrunc(round_trip, 1000), @rem(round_trip, 1000), run.sb.Inet_NtoA(target) });
            run.tap.note("Network RTT: %d.%03dms", .{ @divTrunc(round_trip, 1000), @rem(round_trip, 1000) });
        } else {
            run.tap.diag("  result=%d", .{round_trip});
        }
        if (run.interrupted()) return;

        // 134. 1024 bytes of payload.
        round_trip = ping(run, target, 1024, 3);
        run.tap.ok(round_trip > 0, "ICMP echo: 1024-byte payload [RFC 792]");
        if (round_trip > 0) {
            run.tap.diag("  RTT=%d.%03dms, payload=1024", .{ @divTrunc(round_trip, 1000), @rem(round_trip, 1000) });
        } else {
            run.tap.diag("  result=%d", .{round_trip});
        }
        if (run.interrupted()) return;

        // 135. Five in a row, four of them answered at least.
        var answered: u32 = 0;
        var fastest: i32 = 0x7FFFFFFF;
        var slowest: i32 = 0;
        var sum: i32 = 0;
        for (0..5) |index| {
            const each = ping(run, target, 56, 10 + @as(u16, @intCast(index)));
            if (each > 0) {
                answered += 1;
                fastest = @min(fastest, each);
                slowest = @max(slowest, each);
                sum += each;
            }
        }
        run.tap.ok(answered >= 4, "ICMP echo: multiple pings reliability [RFC 792]");
        run.tap.diag("  received=%u/5", .{answered});
        if (answered > 0) {
            const average: i32 = @divTrunc(sum, @as(i32, @intCast(answered)));
            run.tap.diag("  RTT min=%d.%03dms max=%d.%03dms avg=%d.%03dms", .{
                @divTrunc(fastest, 1000), @rem(fastest, 1000),
                @divTrunc(slowest, 1000), @rem(slowest, 1000),
                @divTrunc(average, 1000), @rem(average, 1000),
            });
        }
        run.tap.note("Multi-ping: %u/5 replies", .{answered});
    }
    if (run.interrupted()) return;

    // 136. An address nothing answers: no reply, or no route.
    round_trip = ping(run, run.sb.Inet_Addr("192.0.2.1"), 56, 99);
    run.tap.ok(round_trip <= 0, "ICMP echo: timeout on unreachable host [RFC 792]");
    if (round_trip == 0) {
        run.tap.diag("  192.0.2.1 (TEST-NET-1): no reply within 3s", .{});
    } else if (round_trip < 0) {
        run.tap.diag("  errno=%d (e.g. ENETUNREACH without default route)", .{run.errno()});
    } else {
        run.tap.diag("  unexpected reply, RTT=%d.%03dms", .{ @divTrunc(round_trip, 1000), @rem(round_trip, 1000) });
    }
}
