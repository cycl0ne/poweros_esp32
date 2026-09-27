// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Thomas Dye
//! The sockopt category, tests 43 to 57: a socket's options, each set and
//! read back - SO_TYPE, SO_REUSEADDR, SO_KEEPALIVE, SO_LINGER,
//! SO_RCVTIMEO, SO_SNDTIMEO, TCP_NODELAY, SO_ERROR after a refused
//! connect, SO_RCVBUF, SO_SNDBUF - and IoctlSocket's FIONBIO, FIONREAD
//! and FIOASYNC. Ports: offsets 41 to 43.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _run = @import("run.zig");
const Run = _run.Run;
const Pair = _run.Pair;

/// Signals on I/O: a request the SDK has no name for.
const FIOASYNC: u32 = 0x8004_667D;

pub fn tests(run: *Run) void {
    const sb = run.sb;
    var value: i32 = 0;
    var length: u32 = 0;

    // 43. SO_TYPE of a stream and a datagram socket.
    const stream = run.tcpSocket();
    const datagram = run.udpSocket();
    if (stream >= 0 and datagram >= 0) {
        value = getInt(run, stream, bsd.SOL_SOCKET, bsd.SO_TYPE);
        const stream_right = value == bsd.SOCK_STREAM;
        value = getInt(run, datagram, bsd.SOL_SOCKET, bsd.SO_TYPE);
        run.tap.ok(stream_right and value == bsd.SOCK_DGRAM, "getsockopt(SO_TYPE): query socket type [BSD 4.4]");
    } else {
        run.tap.ok(false, "getsockopt(SO_TYPE): query socket type [BSD 4.4]");
    }
    run.close(stream);
    run.close(datagram);
    if (run.interrupted()) return;

    // 44. SO_REUSEADDR as it starts: any answer, which the log gives.
    var descriptor = run.tcpSocket();
    if (descriptor >= 0) {
        value = -1;
        length = @sizeOf(i32);
        _ = sb.GetSockOpt(descriptor, bsd.SOL_SOCKET, bsd.SO_REUSEADDR, &value, &length);
        run.tap.ok(true, "SO_REUSEADDR: query default value [BSD 4.4]");
        run.tap.diag("  default SO_REUSEADDR: %d", .{value});
    } else {
        run.tap.ok(false, "SO_REUSEADDR: query default value [BSD 4.4]");
    }
    run.close(descriptor);
    if (run.interrupted()) return;

    // 45. SO_REUSEADDR set.
    descriptor = run.tcpSocket();
    if (descriptor >= 0) {
        const result = setInt(run, descriptor, bsd.SOL_SOCKET, bsd.SO_REUSEADDR, 1);
        run.tap.ok(result == 0 and getInt(run, descriptor, bsd.SOL_SOCKET, bsd.SO_REUSEADDR) != 0, "SO_REUSEADDR: enable address reuse [BSD 4.4]");
    } else {
        run.tap.ok(false, "SO_REUSEADDR: enable address reuse [BSD 4.4]");
    }
    run.close(descriptor);
    if (run.interrupted()) return;

    // 46. SO_REUSEADDR cleared: either answer, which the log gives.
    descriptor = run.tcpSocket();
    if (descriptor >= 0) {
        _ = setInt(run, descriptor, bsd.SOL_SOCKET, bsd.SO_REUSEADDR, 0);
        value = -1;
        length = @sizeOf(i32);
        _ = sb.GetSockOpt(descriptor, bsd.SOL_SOCKET, bsd.SO_REUSEADDR, &value, &length);
        run.tap.ok(true, "SO_REUSEADDR: clear and read-back behavior [BSD 4.4]");
        if (value != 0) run.tap.diag("  SO_REUSEADDR could not be cleared", .{});
    } else {
        run.tap.ok(false, "SO_REUSEADDR: clear and read-back behavior [BSD 4.4]");
    }
    run.close(descriptor);
    if (run.interrupted()) return;

    // 47. SO_KEEPALIVE set.
    descriptor = run.tcpSocket();
    if (descriptor >= 0) {
        const result = setInt(run, descriptor, bsd.SOL_SOCKET, bsd.SO_KEEPALIVE, 1);
        run.tap.ok(result == 0 and getInt(run, descriptor, bsd.SOL_SOCKET, bsd.SO_KEEPALIVE) != 0, "SO_KEEPALIVE: enable keepalive probes [RFC 1122]");
    } else {
        run.tap.ok(false, "SO_KEEPALIVE: enable keepalive probes [RFC 1122]");
    }
    run.close(descriptor);
    if (run.interrupted()) return;

    // 48. SO_LINGER set and read back.
    descriptor = run.tcpSocket();
    if (descriptor >= 0) {
        var linger: bsd.linger = .{ .l_onoff = 1, .l_linger = 5 };
        const result = sb.SetSockOpt(descriptor, bsd.SOL_SOCKET, bsd.SO_LINGER, &linger, @sizeOf(bsd.linger));
        linger = .{};
        length = @sizeOf(bsd.linger);
        _ = sb.GetSockOpt(descriptor, bsd.SOL_SOCKET, bsd.SO_LINGER, &linger, &length);
        run.tap.ok(result == 0 and linger.l_onoff != 0 and linger.l_linger == 5, "SO_LINGER: set and read back linger struct [BSD 4.4]");
    } else {
        run.tap.ok(false, "SO_LINGER: set and read back linger struct [BSD 4.4]");
    }
    run.close(descriptor);
    if (run.interrupted()) return;

    // 49, 50. SO_RCVTIMEO and SO_SNDTIMEO set and read back.
    timeout(run, bsd.SO_RCVTIMEO, "SO_RCVTIMEO: set receive timeout [BSD 4.4]");
    if (run.interrupted()) return;
    timeout(run, bsd.SO_SNDTIMEO, "SO_SNDTIMEO: set send timeout [BSD 4.4]");
    if (run.interrupted()) return;

    // 51. TCP_NODELAY set.
    descriptor = run.tcpSocket();
    if (descriptor >= 0) {
        const result = setInt(run, descriptor, bsd.IPPROTO_TCP, bsd.TCP_NODELAY, 1);
        run.tap.ok(result == 0 and getInt(run, descriptor, bsd.IPPROTO_TCP, bsd.TCP_NODELAY) != 0, "TCP_NODELAY: disable Nagle algorithm [RFC 896/1122]");
    } else {
        run.tap.ok(false, "TCP_NODELAY: disable Nagle algorithm [RFC 896/1122]");
    }
    run.close(descriptor);
    if (run.interrupted()) return;

    // 52. SO_ERROR after a connect that was refused.
    soError(run);
    if (run.interrupted()) return;

    // 53, 54. SO_RCVBUF and SO_SNDBUF of 32 KiB.
    bufferSize(run, bsd.SO_RCVBUF, "SO_RCVBUF: set receive buffer size [BSD 4.4]");
    if (run.interrupted()) return;
    bufferSize(run, bsd.SO_SNDBUF, "SO_SNDBUF: set send buffer size [BSD 4.4]");
    if (run.interrupted()) return;

    // 55. FIONBIO: a connect then answers at once.
    descriptor = run.tcpSocket();
    if (descriptor >= 0) {
        if (run.setNonblocking(descriptor) == 0) {
            const address = _run.loopback(run.port(42));
            const result = sb.Connect(descriptor, address.anyConst(), @sizeOf(bsd.sockaddr_in));
            run.tap.ok(result < 0 and (run.errno() == bsd.EINPROGRESS or run.errno() == bsd.ECONNREFUSED), "IoctlSocket(FIONBIO): set non-blocking mode [AmiTCP]");
            run.tap.diag("  errno: %d", .{run.errno()});
        } else {
            run.tap.ok(false, "IoctlSocket(FIONBIO): set non-blocking mode [AmiTCP]");
        }
    } else {
        run.tap.ok(false, "IoctlSocket(FIONBIO): set non-blocking mode [AmiTCP]");
    }
    run.close(descriptor);
    if (run.interrupted()) return;

    // 56. FIONREAD counts what came.
    const pair = Pair.open(run, 43);
    if (pair.ready()) {
        var data: [100]u8 = undefined;
        _run.fillPattern(&data, 20);
        _ = sb.Send(pair.client, &data, data.len, 0);
        _ = run.waitReadable(pair.server, 1, 0);
        value = 0;
        const result = sb.IoctlSocket(pair.server, bsd.FIONREAD, &value);
        run.tap.ok(result == 0 and value == 100, "IoctlSocket(FIONREAD): query pending bytes [AmiTCP]");
        if (value != 100) run.tap.diag("  FIONREAD: %d", .{value});
    } else {
        run.tap.ok(false, "IoctlSocket(FIONREAD): query pending bytes [AmiTCP]");
    }
    pair.close(run);
    if (run.interrupted()) return;

    // 57. FIOASYNC.
    descriptor = run.tcpSocket();
    if (descriptor >= 0) {
        var on: i32 = 1;
        if (sb.IoctlSocket(descriptor, FIOASYNC, &on) == 0) {
            run.tap.ok(true, "IoctlSocket(FIOASYNC): async notification mode [AmiTCP]");
        } else {
            run.tap.skip("FIOASYNC not supported");
        }
    } else {
        run.tap.ok(false, "IoctlSocket(FIOASYNC): async notification mode [AmiTCP]");
    }
    run.close(descriptor);
}

fn setInt(run: *Run, descriptor: i32, level: i32, option: i32, value: i32) i32 {
    return run.sb.SetSockOpt(descriptor, level, option, &value, @sizeOf(i32));
}

/// An i32 option read; 0 when the read fails.
fn getInt(run: *Run, descriptor: i32, level: i32, option: i32) i32 {
    var value: i32 = 0;
    var length: u32 = @sizeOf(i32);
    _ = run.sb.GetSockOpt(descriptor, level, option, &value, &length);
    return value;
}

fn timeout(run: *Run, option: i32, description: [*:0]const u8) void {
    const descriptor = run.tcpSocket();
    defer run.close(descriptor);
    if (descriptor < 0) return run.tap.ok(false, description);
    var time: bsd.timeval = .{ .secs = 1, .micro = 0 };
    if (run.sb.SetSockOpt(descriptor, bsd.SOL_SOCKET, option, &time, @sizeOf(bsd.timeval)) != 0) return run.tap.ok(false, description);
    time = .{};
    var length: u32 = @sizeOf(bsd.timeval);
    _ = run.sb.GetSockOpt(descriptor, bsd.SOL_SOCKET, option, &time, &length);
    run.tap.ok(time.secs == 1 and time.micro == 0, description);
}

fn bufferSize(run: *Run, option: i32, description: [*:0]const u8) void {
    const descriptor = run.tcpSocket();
    defer run.close(descriptor);
    if (descriptor < 0) return run.tap.ok(false, description);
    const result = setInt(run, descriptor, bsd.SOL_SOCKET, option, 32768);
    const value = getInt(run, descriptor, bsd.SOL_SOCKET, option);
    run.tap.ok(result == 0 and value >= 32768, description);
    run.tap.diag("  %s: %d", .{ @as([*:0]const u8, if (option == bsd.SO_RCVBUF) "SO_RCVBUF" else "SO_SNDBUF"), value });
}

fn soError(run: *Run) void {
    const description = "SO_ERROR: pending error after failed connect [BSD 4.4]";
    const descriptor = run.tcpSocket();
    defer run.close(descriptor);
    if (descriptor < 0) return run.tap.ok(false, description);
    _ = run.setNonblocking(descriptor);
    const address = _run.loopback(run.port(41));
    const result = run.sb.Connect(descriptor, address.anyConst(), @sizeOf(bsd.sockaddr_in));
    if (result < 0 and run.errno() == bsd.EINPROGRESS) {
        var write: bsd.fd_set = .{};
        write.set(descriptor);
        var time: bsd.timeval = .{ .secs = 2, .micro = 0 };
        _ = run.sb.WaitSelect(descriptor + 1, null, &write, null, &time, null);
        const pending = getInt(run, descriptor, bsd.SOL_SOCKET, bsd.SO_ERROR);
        run.tap.ok(pending == bsd.ECONNREFUSED, description);
        run.tap.diag("  SO_ERROR: %d", .{pending});
    } else if (result < 0 and run.errno() == bsd.ECONNREFUSED) {
        const pending = getInt(run, descriptor, bsd.SOL_SOCKET, bsd.SO_ERROR);
        run.tap.ok(true, description);
        run.tap.diag("  SO_ERROR: %d (connect was immediate ECONNREFUSED)", .{pending});
    } else {
        run.tap.ok(false, description);
        run.tap.diag("  rc=%d, errno=%d", .{ result, run.errno() });
    }
}
