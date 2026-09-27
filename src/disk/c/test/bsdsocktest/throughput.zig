// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Thomas Dye
//! The throughput category, tests 137 to 142: how fast data goes - 512
//! KiB over TCP on the loopback, 200 datagrams of 1 KiB over UDP on the
//! loopback, and 1 MiB over TCP on the loopback with the time of each
//! 100 KiB; with the host helper the same to its sink and its UDP echo.
//! A test passes when the data went; the rates are in the notes. Ports:
//! offsets 180 to 183.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _run = @import("run.zig");
const Run = _run.Run;
const Pair = _run.Pair;
const helper = @import("helper.zig");

const tcp_bytes: u32 = 512 * 1024;
const sustained_bytes: u32 = 1024 * 1024;
const udp_count: u32 = 200;
const udp_size: u32 = 1024;
const segment_bytes: u32 = 100 * 1024;
const segments = 10;

/// The milliseconds each 100 KiB of a sustained send took.
const Segments = struct {
    ms: [segments]u32 = @splat(0),
    count: u32 = 0,
    start: u64 = 0,

    /// Every segment `sent` has finished, timed.
    fn mark(times: *Segments, run: *Run, sent: u32) void {
        while (times.count < segments and sent >= (times.count + 1) * segment_bytes) {
            const now = run.now();
            times.ms[times.count] = @intCast((now - times.start + 500) / 1000);
            times.start = now;
            times.count += 1;
        }
    }

    fn report(times: *const Segments, run: *Run) void {
        if (times.count == 0) return;
        var fastest = times.ms[0];
        var slowest = times.ms[0];
        for (times.ms[1..times.count]) |ms| {
            fastest = @min(fastest, ms);
            slowest = @max(slowest, ms);
        }
        run.tap.diag("  segments=%u seg_min=%ums seg_max=%ums", .{ times.count, fastest, slowest });
        for (times.ms[0..times.count], 0..) |ms, index| {
            run.tap.diag("    seg[%u]: %ums %uKB/s", .{ @as(u32, @intCast(index)), ms, rate(segment_bytes, ms) });
        }
    }
};

/// KiB per second.
fn rate(bytes: u32, ms: u32) u32 {
    return if (ms > 0) bytes / 1024 * 1000 / ms else 0;
}

pub fn tests(run: *Run) void {
    _run.fillPattern(&run.buffers.send, 0);

    // 137. 512 KiB over TCP on the loopback.
    {
        const pair = Pair.open(run, 180);
        defer pair.close(run);
        if (pair.ready()) {
            const started = run.now();
            const moved = loopbackStream(run, pair, tcp_bytes, null);
            const ms = run.msSince(started);
            run.tap.ok(moved.received >= tcp_bytes * 90 / 100, "Throughput: TCP loopback send/recv [benchmark]");
            run.tap.diag("  sent=%u recv=%u ms=%u KB/s=%u", .{ moved.sent, moved.received, ms, rate(moved.received, ms) });
            run.tap.note("TCP loopback: %u KB/s", .{rate(moved.received, ms)});
        } else {
            run.tap.ok(false, "Throughput: TCP loopback send/recv [benchmark]");
        }
    }
    if (run.interrupted()) return;

    // 138. 512 KiB to the helper's sink.
    if (!run.helper.connected) {
        run.tap.skip("host helper not connected");
    } else {
        const started = run.now();
        const sent = toSink(run, tcp_bytes, null);
        const ms = run.msSince(started);
        if (sent) |bytes| {
            run.tap.ok(bytes > 0, "Throughput: TCP via network to host [benchmark]");
            run.tap.diag("  sent=%u ms=%u KB/s=%u", .{ bytes, ms, rate(bytes, ms) });
            run.tap.note("TCP network: %u KB/s", .{rate(bytes, ms)});
        } else {
            run.tap.ok(false, "Throughput: TCP via network to host [benchmark]");
        }
    }
    if (run.interrupted()) return;

    // 139. 200 datagrams on the loopback.
    loopbackDatagrams(run);
    if (run.interrupted()) return;

    // 140. 200 datagrams to the helper's echo.
    if (!run.helper.connected) {
        run.tap.skip("host helper not connected");
    } else {
        networkDatagrams(run);
    }
    if (run.interrupted()) return;

    // 141. 1 MiB over TCP on the loopback, timed per 100 KiB.
    {
        const pair = Pair.open(run, 183);
        defer pair.close(run);
        if (pair.ready()) {
            var times: Segments = .{};
            const started = run.now();
            times.start = started;
            const moved = loopbackStream(run, pair, sustained_bytes, &times);
            const ms = run.msSince(started);
            run.tap.ok(moved.received >= sustained_bytes, "Throughput: TCP sustained 1MB+ loopback [benchmark]");
            run.tap.diag("  sent=%u recv=%u total_ms=%u overall_KB/s=%u", .{ moved.sent, moved.received, ms, rate(moved.received, ms) });
            run.tap.note("TCP sustained loopback: %u KB/s", .{rate(moved.received, ms)});
            times.report(run);
        } else {
            run.tap.ok(false, "Throughput: TCP sustained 1MB+ loopback [benchmark]");
        }
    }
    if (run.interrupted()) return;

    // 142. 1 MiB to the helper's sink, timed per 100 KiB.
    if (!run.helper.connected) {
        run.tap.skip("host helper not connected");
    } else {
        var times: Segments = .{};
        const started = run.now();
        times.start = started;
        const sent = toSink(run, sustained_bytes, &times);
        const ms = run.msSince(started);
        if (sent) |bytes| {
            run.tap.ok(bytes >= sustained_bytes, "Throughput: TCP sustained 1MB+ via network [benchmark]");
            run.tap.diag("  sent=%u total_ms=%u overall_KB/s=%u", .{ bytes, ms, rate(bytes, ms) });
            run.tap.note("TCP sustained network: %u KB/s", .{rate(bytes, ms)});
            times.report(run);
        } else {
            run.tap.ok(false, "Throughput: TCP sustained 1MB+ via network [benchmark]");
        }
    }
}

const Moved = struct { sent: u32, received: u32 };

/// `total` bytes from the client to the server of a loopback pair, both
/// never waiting, driven by WaitSelect; the client shuts its side when
/// all went.
fn loopbackStream(run: *Run, pair: Pair, total: u32, times: ?*Segments) Moved {
    const sb = run.sb;
    const send = &run.buffers.send;
    const receive = &run.buffers.receive;
    _ = run.setNonblocking(pair.client);
    _ = run.setNonblocking(pair.server);
    var moved: Moved = .{ .sent = 0, .received = 0 };
    var send_done = false;
    const count = @max(pair.client, pair.server) + 1;
    while (moved.received < total) {
        var read: bsd.fd_set = .{};
        var write: bsd.fd_set = .{};
        read.set(pair.server);
        if (!send_done) write.set(pair.client);
        var time: bsd.timeval = .{ .secs = 10 };
        if (sb.WaitSelect(count, &read, &write, null, &time, null) <= 0) break;
        if (!send_done and write.isSet(pair.client)) {
            const chunk: u32 = @min(total - moved.sent, @as(u32, send.len));
            const sent = sb.Send(pair.client, send, chunk, 0);
            if (sent > 0) {
                moved.sent += @intCast(sent);
                if (times) |segments_seen| segments_seen.mark(run, moved.sent);
            }
            if (moved.sent >= total) {
                _ = sb.Shutdown(pair.client, bsd.SHUT_WR);
                send_done = true;
            }
        }
        if (read.isSet(pair.server)) {
            const got = sb.Recv(pair.server, receive, receive.len, 0);
            if (got > 0) moved.received += @intCast(got) else if (got == 0) break;
        }
    }
    return moved;
}

/// `total` bytes to the helper's sink: how many went, or null when it
/// could not be reached.
fn toSink(run: *Run, total: u32, times: ?*Segments) ?u32 {
    const send = &run.buffers.send;
    const descriptor = run.helper.service(run, helper.tcp_sink_port);
    if (descriptor < 0) return null;
    defer run.close(descriptor);
    var sent: u32 = 0;
    while (sent < total) {
        const chunk: u32 = @min(total - sent, @as(u32, send.len));
        const got = run.sb.Send(descriptor, send, chunk, 0);
        if (got <= 0) break;
        sent += @intCast(got);
        if (times) |segments_seen| segments_seen.mark(run, sent);
    }
    return sent;
}

/// Every datagram waiting on `descriptor`, taken until none comes for a
/// second: how many.
fn drain(run: *Run, descriptor: i32) u32 {
    const receive = &run.buffers.receive;
    _ = run.setNonblocking(descriptor);
    var received: u32 = 0;
    while (run.waitReadable(descriptor, 1, 0) > 0) {
        while (run.sb.Recv(descriptor, receive, receive.len, 0) > 0) received += 1;
    }
    return received;
}

fn loopbackDatagrams(run: *Run) void {
    const description = "Throughput: UDP loopback [benchmark]";
    const sb = run.sb;
    const send = &run.buffers.send;
    const from = run.udpSocket();
    defer run.close(from);
    const to = run.udpSocket();
    defer run.close(to);
    if (from < 0 or to < 0) return run.tap.ok(false, description);
    const from_address = _run.loopback(run.port(181));
    _ = sb.Bind(from, from_address.anyConst(), @sizeOf(bsd.sockaddr_in));
    const to_address = _run.loopback(run.port(182));
    _ = sb.Bind(to, to_address.anyConst(), @sizeOf(bsd.sockaddr_in));
    const started = run.now();
    var index: u32 = 0;
    while (index < udp_count) : (index += 1) {
        _run.fillPattern(send[0..udp_size], index);
        _ = sb.SendTo(from, send, udp_size, 0, to_address.anyConst(), @sizeOf(bsd.sockaddr_in));
    }
    const received = drain(run, to);
    const ms = run.msSince(started);
    const speed = rate(received * udp_size, ms);
    run.tap.ok(received > 0, description);
    run.tap.diag("  sent=%u recv=%u loss=%u%% ms=%u KB/s=%u", .{ udp_count, received, (udp_count - @min(received, udp_count)) * 100 / udp_count, ms, speed });
    run.tap.note("UDP loopback: %u KB/s (%u/%u received)", .{ speed, received, udp_count });
}

fn networkDatagrams(run: *Run) void {
    const description = "Throughput: UDP via network to host [benchmark]";
    const sb = run.sb;
    const send = &run.buffers.send;
    const descriptor = run.udpSocket();
    defer run.close(descriptor);
    if (descriptor < 0) return run.tap.ok(false, description);
    const to = run.helper.at(helper.udp_echo_port);
    const started = run.now();
    var index: u32 = 0;
    while (index < udp_count) : (index += 1) {
        _run.fillPattern(send[0..udp_size], index);
        _ = sb.SendTo(descriptor, send, udp_size, 0, to.anyConst(), @sizeOf(bsd.sockaddr_in));
    }
    const received = drain(run, descriptor);
    const ms = run.msSince(started);
    const speed = rate(received * udp_size, ms);
    run.tap.ok(received > 0, description);
    run.tap.diag("  sent=%u echoed=%u loss=%u%% ms=%u KB/s=%u", .{ udp_count, received, (udp_count - @min(received, udp_count)) * 100 / udp_count, ms, speed });
    run.tap.note("UDP network: %u KB/s (%u/%u echoed)", .{ speed, received, udp_count });
}
