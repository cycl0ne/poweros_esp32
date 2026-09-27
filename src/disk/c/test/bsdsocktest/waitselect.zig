// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Thomas Dye
//! The waitselect category, tests 58 to 72: WaitSelect - readiness to
//! read and to write, a timeout of zero, one that runs out and none at
//! all, a pure delay, out-of-band data in the exception set, several
//! sockets at once, a signal that breaks the wait and one that does not,
//! a closed descriptor, `count` one too small, a descriptor past 64, a
//! connect finishing, and a peer that closes. Ports: offsets 60 to 73.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _run = @import("run.zig");
const Run = _run.Run;
const Pair = _run.Pair;

/// Out-of-band data: a flag the SDK has no name for.
const MSG_OOB: u32 = 0x1;

pub fn tests(run: *Run) void {
    const sb = run.sb;
    var bytes: [100]u8 = undefined;
    var read: bsd.fd_set = .{};
    var write: bsd.fd_set = .{};
    var time: bsd.timeval = .{};

    // 58. Readable once data came.
    var pair = Pair.open(run, 60);
    if (pair.ready()) {
        _run.fillPattern(&bytes, 70);
        _ = sb.Send(pair.client, &bytes, 100, 0);
        read.zero();
        read.set(pair.server);
        time = .{ .secs = 2 };
        const result = sb.WaitSelect(pair.server + 1, &read, null, null, &time, null);
        run.tap.ok(result >= 1 and read.isSet(pair.server), "WaitSelect(): read readiness after data send [AmiTCP]");
    } else {
        run.tap.ok(false, "WaitSelect(): read readiness after data send [AmiTCP]");
    }
    pair.close(run);
    if (run.interrupted()) return;

    // 59. A connected socket is writable.
    pair = Pair.open(run, 61);
    if (pair.ready()) {
        write.zero();
        write.set(pair.client);
        time = .{ .secs = 2 };
        const result = sb.WaitSelect(pair.client + 1, null, &write, null, &time, null);
        run.tap.ok(result >= 1 and write.isSet(pair.client), "WaitSelect(): write readiness on connected socket [AmiTCP]");
    } else {
        run.tap.ok(false, "WaitSelect(): write readiness on connected socket [AmiTCP]");
    }
    pair.close(run);
    if (run.interrupted()) return;

    // 60. A timeout of zero polls.
    pair = Pair.open(run, 62);
    if (pair.server >= 0) {
        const started = run.now();
        const result = run.waitReadable(pair.server, 0, 0);
        const ms = run.msSince(started);
        run.tap.ok(result == 0 and ms < 100, "WaitSelect(): tv={0,0} immediate poll [AmiTCP]");
        run.tap.diag("  elapsed: %ums, return: %d", .{ ms, result });
    } else {
        run.tap.ok(false, "WaitSelect(): tv={0,0} immediate poll [AmiTCP]");
    }
    pair.close(run);
    if (run.interrupted()) return;

    // 61. A timeout that runs out.
    pair = Pair.open(run, 63);
    if (pair.server >= 0) {
        const started = run.now();
        const result = run.waitReadable(pair.server, 1, 0);
        const ms = run.msSince(started);
        run.tap.ok(result == 0 and ms >= 500 and ms <= 2000, "WaitSelect(): timeout fires when idle [AmiTCP]");
        run.tap.diag("  elapsed: %ums, return: %d", .{ ms, result });
    } else {
        run.tap.ok(false, "WaitSelect(): timeout fires when idle [AmiTCP]");
        run.tap.diag("  listener=%d client=%d server=%d errno=%d", .{ pair.listener, pair.client, pair.server, run.errno() });
    }
    pair.close(run);
    if (run.interrupted()) return;

    // 62. No timeout: a connection waiting makes the listener readable.
    const port = run.port(64);
    var listener = run.loopbackListener(port);
    var client = run.loopbackClient(port);
    if (listener >= 0 and client >= 0) {
        read.zero();
        read.set(listener);
        const result = sb.WaitSelect(listener + 1, &read, null, null, null, null);
        run.tap.ok(result >= 1 and read.isSet(listener), "WaitSelect(): NULL timeout blocks until activity [AmiTCP]");
    } else {
        run.tap.ok(false, "WaitSelect(): NULL timeout blocks until activity [AmiTCP]");
    }
    if (listener >= 0) run.close(run.acceptOne(listener));
    run.close(client);
    run.close(listener);
    if (run.interrupted()) return;

    // 63. No sets, a timeout: a delay.
    {
        time = .{ .secs = 0, .micro = 250000 };
        const started = run.now();
        const result = sb.WaitSelect(0, null, null, null, &time, null);
        const ms = run.msSince(started);
        run.tap.ok(result == 0 and ms >= 100 and ms <= 600, "WaitSelect(): all NULL fdsets + timeout = delay [AmiTCP]");
        run.tap.diag("  elapsed: %ums", .{ms});
    }
    if (run.interrupted()) return;

    // 64. Out-of-band data in the exception set.
    pair = Pair.open(run, 65);
    if (pair.ready()) {
        bytes[0] = 0xAB;
        if (sb.Send(pair.client, &bytes, 1, MSG_OOB) < 0) {
            run.tap.skip("MSG_OOB not supported");
        } else {
            var except: bsd.fd_set = .{};
            except.set(pair.server);
            time = .{ .secs = 2 };
            const result = sb.WaitSelect(pair.server + 1, null, null, &except, &time, null);
            run.tap.ok(result >= 1 and except.isSet(pair.server), "WaitSelect(): exceptfds detects OOB data [AmiTCP]");
            if (result < 0) run.tap.diag("  rc=%d, errno=%d", .{ result, run.errno() });
        }
    } else {
        run.tap.ok(false, "WaitSelect(): exceptfds detects OOB data [AmiTCP]");
    }
    pair.close(run);
    if (run.interrupted()) return;

    // 65. Three sockets readable at once.
    several(run);
    if (run.interrupted()) return;

    // 66. A signal breaks a wait with no timeout.
    var signal = run.allocSignal();
    if (signal >= 0) {
        const mask = @as(u32, 1) << @intCast(signal);
        listener = run.loopbackListener(run.port(69));
        if (listener >= 0) {
            read.zero();
            read.set(listener);
            run.sys.Signal(run.sys.FindTask(null).?, mask);
            var signals = mask;
            const result = sb.WaitSelect(listener + 1, &read, null, null, null, &signals);
            run.tap.ok(result == 0 and !read.isSet(listener) and signals & mask != 0, "WaitSelect(): Amiga signal interruption [AmiTCP]");
            run.tap.diag("  rc=%d, fd_isset=%u, sigmask=0x%08x", .{ result, @as(u32, @intFromBool(read.isSet(listener))), signals });
        } else {
            run.tap.ok(false, "WaitSelect(): Amiga signal interruption [AmiTCP]");
        }
        run.close(listener);
        _ = run.sys.SetSignal(0, mask);
        run.freeSignal(signal);
    } else {
        run.tap.skip("could not allocate signal");
    }
    if (run.interrupted()) return;

    // 67. A socket ready with a signal mask given: the socket answers.
    signal = run.allocSignal();
    if (signal >= 0) {
        pair = Pair.open(run, 70);
        if (pair.ready()) {
            _run.fillPattern(&bytes, 79);
            _ = sb.Send(pair.client, &bytes, 100, 0);
            read.zero();
            read.set(pair.server);
            var signals = @as(u32, 1) << @intCast(signal);
            time = .{ .secs = 2 };
            const result = sb.WaitSelect(pair.server + 1, &read, null, null, &time, &signals);
            run.tap.ok(result >= 1 and read.isSet(pair.server), "WaitSelect(): signal mask passthrough [AmiTCP]");
            if (signals == 0) run.tap.diag("  sigmask cleared (replaced by received signals = none)", .{}) else run.tap.diag("  sigmask unchanged on fd readiness return", .{});
            run.tap.diag("  rc=%d, sigmask=0x%08x", .{ result, signals });
        } else {
            run.tap.ok(false, "WaitSelect(): signal mask passthrough [AmiTCP]");
        }
        pair.close(run);
        run.freeSignal(signal);
    } else {
        run.tap.skip("could not allocate signal");
    }
    if (run.interrupted()) return;

    // 68. A closed descriptor: any answer, which the log gives.
    client = run.tcpSocket();
    if (client >= 0) {
        const closed = client;
        run.close(client);
        const result = run.waitReadable(closed, 0, 0);
        run.tap.ok(true, "WaitSelect(): invalid descriptor handling [AmiTCP]");
        if (result != -1 or run.errno() != bsd.EBADF) run.tap.diag("  rc=%d, errno=%d (EBADF=%d)", .{ result, run.errno(), bsd.EBADF });
    } else {
        run.tap.ok(false, "WaitSelect(): invalid descriptor handling [AmiTCP]");
    }
    if (run.interrupted()) return;

    // 69. `count` is the highest descriptor plus one: one less misses it.
    pair = Pair.open(run, 71);
    if (pair.ready()) {
        _run.fillPattern(bytes[0..10], 81);
        _ = sb.Send(pair.client, &bytes, 10, 0);
        const result_a = run.waitReadable(pair.server, 2, 0);
        run.setReceiveTimeout(pair.server, 1);
        _ = sb.Recv(pair.server, &bytes, bytes.len, 0);
        _run.fillPattern(bytes[0..10], 82);
        _ = sb.Send(pair.client, &bytes, 10, 0);
        run.delay(0, 250000);
        read.zero();
        read.set(pair.server);
        time = .{};
        const result_b = sb.WaitSelect(pair.server, &read, null, null, &time, null);
        run.tap.ok(result_a >= 1 and result_b == 0, "WaitSelect(): nfds = highest_fd + 1 [AmiTCP]");
        run.tap.diag("  result_a (nfds=%d+1): %d, result_b (nfds=%d): %d", .{ pair.server, result_a, pair.server, result_b });
    } else {
        run.tap.ok(false, "WaitSelect(): nfds = highest_fd + 1 [AmiTCP]");
    }
    pair.close(run);
    if (run.interrupted()) return;

    // 70. A descriptor past 64.
    many(run);
    if (run.interrupted()) return;

    // 71. A connect that does not wait, finished.
    connectReady(run);
    if (run.interrupted()) return;

    // 72. Readable, and the end read, once the peer closed.
    pair = Pair.open(run, 73);
    if (pair.ready()) {
        run.close(pair.server);
        pair.server = -1;
        var result = run.waitReadable(pair.client, 2, 0);
        if (result >= 1) {
            result = sb.Recv(pair.client, &bytes, bytes.len, 0);
            run.tap.ok(result == 0, "WaitSelect(): readable after peer close (EOF) [AmiTCP]");
            if (result != 0) run.tap.diag("  recv returned %d, errno=%d", .{ result, run.errno() });
        } else {
            run.tap.ok(false, "WaitSelect(): readable after peer close (EOF) [AmiTCP]");
            run.tap.diag("  rc=%d", .{result});
        }
    } else {
        run.tap.ok(false, "WaitSelect(): readable after peer close (EOF) [AmiTCP]");
    }
    pair.close(run);
}

fn several(run: *Run) void {
    const description = "WaitSelect(): multiple sockets in readfds [AmiTCP]";
    var pairs: [3]Pair = undefined;
    for (&pairs, 0..) |*pair, index| pair.* = Pair.open(run, 66 + @as(u16, @intCast(index)));
    defer for (pairs) |pair| pair.close(run);
    for (pairs) |pair| {
        if (pair.server < 0) return run.tap.ok(false, description);
    }
    var bytes: [10]u8 = undefined;
    for (pairs, 0..) |pair, index| {
        _run.fillPattern(&bytes, 77 + @as(u32, @intCast(index)));
        _ = run.sb.Send(pair.client, &bytes, bytes.len, 0);
    }
    var read: bsd.fd_set = .{};
    var count: i32 = 0;
    for (pairs) |pair| {
        read.set(pair.server);
        if (pair.server + 1 > count) count = pair.server + 1;
    }
    var time: bsd.timeval = .{ .secs = 2 };
    const result = run.sb.WaitSelect(count, &read, null, null, &time, null);
    var ready: u32 = 0;
    for (pairs) |pair| {
        if (read.isSet(pair.server)) ready += 1;
    }
    run.tap.ok(result >= 1 and ready == 3, description);
    run.tap.diag("  return: %d, ready: %u of 3", .{ result, ready });
}

fn many(run: *Run) void {
    const description = "WaitSelect(): >64 descriptors [AmiTCP]";
    const original = run.getTag(bsd.SBTC_DTABLESIZE);
    defer if (original < 66 and original > 0) {
        _ = run.setTag(bsd.SBTC_DTABLESIZE, original);
    };
    if (original < 66) {
        _ = run.setTag(bsd.SBTC_DTABLESIZE, 128);
        const now = run.getTag(bsd.SBTC_DTABLESIZE);
        if (now < 66) {
            run.tap.skip("dtablesize expansion not supported");
            run.tap.diag("  original: %u, after SET 128: %u", .{ original, now });
            return;
        }
    }
    const descriptors = run.buffers.descriptors[0..65];
    @memset(descriptors, -1);
    defer run.closeAll(descriptors);
    var opened: u32 = 0;
    for (descriptors) |*descriptor| {
        descriptor.* = run.tcpSocket();
        if (descriptor.* < 0) break;
        opened += 1;
    }
    if (opened < 65) {
        run.tap.skip("could not open 65 sockets");
        run.tap.diag("  opened %u before failure", .{opened});
        return;
    }
    const highest = descriptors[64];
    if (highest < 64) return run.tap.skip("65 sockets opened but highest fd < 64");
    const result = run.waitReadable(highest, 0, 0);
    run.tap.ok(result == 0, description);
    run.tap.diag("  highest fd: %d, return: %d", .{ highest, result });
}

fn connectReady(run: *Run) void {
    const description = "WaitSelect(): non-blocking connect completion [AmiTCP]";
    const sb = run.sb;
    const port = run.port(72);
    const listener = run.loopbackListener(port);
    defer run.close(listener);
    if (listener < 0) return run.tap.ok(false, description);
    const client = run.tcpSocket();
    defer run.close(client);
    if (client < 0) return run.tap.ok(false, description);
    _ = run.setNonblocking(client);
    const address = _run.loopback(port);
    const result = sb.Connect(client, address.anyConst(), @sizeOf(bsd.sockaddr_in));
    if (result == 0) {
        run.tap.ok(true, description);
        run.tap.diag("  non-blocking connect returned 0 on loopback", .{});
    } else if (run.errno() == bsd.EINPROGRESS) {
        var write: bsd.fd_set = .{};
        write.set(client);
        var time: bsd.timeval = .{ .secs = 2 };
        const ready = sb.WaitSelect(client + 1, null, &write, null, &time, null);
        if (ready >= 1 and write.isSet(client)) {
            var pending: i32 = -1;
            var length: u32 = @sizeOf(i32);
            _ = sb.GetSockOpt(client, bsd.SOL_SOCKET, bsd.SO_ERROR, &pending, &length);
            run.tap.ok(pending == 0, description);
            run.tap.diag("  SO_ERROR: %d", .{pending});
        } else {
            run.tap.ok(false, description);
        }
    } else {
        run.tap.ok(false, description);
        run.tap.diag("  errno: %d", .{run.errno()});
    }
    run.close(run.acceptOne(listener));
}
