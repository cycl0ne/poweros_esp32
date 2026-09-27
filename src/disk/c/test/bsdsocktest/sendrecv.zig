// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Thomas Dye
//! The sendrecv category, tests 24 to 42: data moved - Send and Recv,
//! SendTo and RecvFrom, MSG_PEEK and MSG_OOB, what a socket that never
//! waits answers, the end of a connection; then, with the host helper,
//! 64 KiB and 256 KiB echoed, a datagram echoed, and a connection the
//! helper makes. Ports: offsets 20 to 39, and 161.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _run = @import("run.zig");
const Run = _run.Run;
const Pair = _run.Pair;
const helper = @import("helper.zig");

pub fn tests(run: *Run) void {
    const sb = run.sb;
    const send = &run.buffers.send;
    const receive = &run.buffers.receive;

    // 24. 100 bytes over TCP.
    var pair = Pair.open(run, 20);
    if (pair.ready()) {
        _run.fillPattern(send[0..100], 1);
        _ = sb.Send(pair.client, send, 100, 0);
        run.setReceiveTimeout(pair.server, 2);
        const got = sb.Recv(pair.server, receive, receive.len, 0);
        run.tap.ok(got == 100 and _run.checkPattern(receive[0..100], 1) == 0, "send()/recv(): 100-byte TCP transfer [BSD 4.4]");
    } else {
        run.tap.ok(false, "send()/recv(): 100-byte TCP transfer [BSD 4.4]");
    }
    pair.close(run);
    if (run.interrupted()) return;

    // 25. 8192 bytes, received in as many pieces as they come.
    pair = Pair.open(run, 21);
    if (pair.ready()) {
        _run.fillPattern(send[0..8192], 2);
        _ = sb.Send(pair.client, send, 8192, 0);
        run.setReceiveTimeout(pair.server, 3);
        const total = _run.receiveAll(sb, pair.server, receive[0..8192]);
        run.tap.ok(total == 8192 and _run.checkPattern(receive[0..8192], 2) == 0, "send()/recv(): 8192-byte TCP transfer (multi-recv) [BSD 4.4]");
        if (total != 8192) run.tap.diag("  received %u of 8192 bytes", .{total});
    } else {
        run.tap.ok(false, "send()/recv(): 8192-byte TCP transfer (multi-recv) [BSD 4.4]");
    }
    pair.close(run);
    if (run.interrupted()) return;

    // 26. MSG_PEEK leaves the bytes where they are.
    pair = Pair.open(run, 22);
    if (pair.ready()) {
        _run.fillPattern(send[0..50], 3);
        _ = sb.Send(pair.client, send, 50, 0);
        run.setReceiveTimeout(pair.server, 2);
        var got = sb.Recv(pair.server, receive, receive.len, bsd.MSG_PEEK);
        if (got == 50 and _run.checkPattern(receive[0..50], 3) == 0) {
            @memset(receive, 0);
            got = sb.Recv(pair.server, receive, receive.len, 0);
            run.tap.ok(got == 50 and _run.checkPattern(receive[0..50], 3) == 0, "recv(MSG_PEEK): read without consuming [BSD 4.4]");
        } else {
            run.tap.ok(false, "recv(MSG_PEEK): read without consuming [BSD 4.4]");
        }
    } else {
        run.tap.ok(false, "recv(MSG_PEEK): read without consuming [BSD 4.4]");
    }
    pair.close(run);
    if (run.interrupted()) return;

    // 27. Urgent data.
    pair = Pair.open(run, 23);
    if (pair.ready()) {
        send[0] = 0xAB;
        if (sb.Send(pair.client, send, 1, bsd.MSG_OOB) < 0) {
            run.tap.skip("MSG_OOB send not supported");
        } else {
            run.setReceiveTimeout(pair.server, 2);
            receive[0] = 0;
            const got = sb.Recv(pair.server, receive, 1, bsd.MSG_OOB);
            run.tap.ok(got == 1 and receive[0] == 0xAB, "recv(MSG_OOB): urgent data delivery [BSD 4.4]");
            if (got != 1 or receive[0] != 0xAB) run.tap.diag("  recv(MSG_OOB): rc=%d byte=0x%02x errno=%d", .{ got, @as(u32, receive[0]), run.errno() });
        }
    } else {
        run.tap.ok(false, "recv(MSG_OOB): urgent data delivery [BSD 4.4]");
    }
    pair.close(run);
    if (run.interrupted()) return;

    // 28 to 30. A datagram over the loopback: plainly, after a socket
    // made and closed first, and once more.
    datagram(run, 24, 3, false, true, "sendto()/recvfrom(): UDP datagram loopback [RFC 768]");
    if (run.interrupted()) return;
    datagram(run, 25, 4, true, false, "sendto(): correct dispatch after prior socket ops [BSD 4.4]");
    if (run.interrupted()) return;
    datagram(run, 26, 5, false, false, "sendto(): on independently created socket [BSD 4.4]");
    if (run.interrupted()) return;

    // 31, 32. SendMsg and RecvMsg.
    run.tap.skip("no SendMsg/RecvMsg");
    if (run.interrupted()) return;
    run.tap.skip("no SendMsg/RecvMsg");
    if (run.interrupted()) return;

    // 33. Recv on a socket that never waits, with nothing come.
    pair = Pair.open(run, 29);
    if (pair.server >= 0) {
        _ = run.setNonblocking(pair.server);
        const got = sb.Recv(pair.server, receive, receive.len, 0);
        run.tap.ok(got < 0 and run.errno() == bsd.EWOULDBLOCK, "recv(): EWOULDBLOCK on empty non-blocking socket [BSD 4.4]");
    } else {
        run.tap.ok(false, "recv(): EWOULDBLOCK on empty non-blocking socket [BSD 4.4]");
    }
    pair.close(run);
    if (run.interrupted()) return;

    // 34. Send on a socket that never waits, until it is full.
    pair = Pair.open(run, 30);
    if (pair.ready()) {
        _ = run.setNonblocking(pair.client);
        _run.fillPattern(send, 8);
        var total: u32 = 0;
        var sent: i32 = 0;
        while (total < 1048576) {
            sent = sb.Send(pair.client, send, send.len, 0);
            if (sent < 0) break;
            total += @intCast(sent);
        }
        if (sent < 0 and run.errno() == bsd.EWOULDBLOCK) {
            run.tap.ok(true, "send(): EWOULDBLOCK when buffer full [BSD 4.4]");
            run.tap.diag("  sent %u bytes before EWOULDBLOCK", .{total});
        } else {
            run.tap.skip("send buffer never filled (>1MB)");
        }
    } else {
        run.tap.ok(false, "send(): EWOULDBLOCK when buffer full [BSD 4.4]");
    }
    pair.close(run);
    if (run.interrupted()) return;

    // 35. Send after the peer closed: an error, at once or after the
    // peer's reset.
    pair = Pair.open(run, 31);
    if (pair.ready()) {
        run.close(pair.server);
        pair.server = -1;
        run.setReceiveTimeout(pair.client, 1);
        _ = sb.Recv(pair.client, receive, receive.len, 0);
        _run.fillPattern(send[0..100], 9);
        var passed = false;
        var attempts: u32 = 0;
        while (attempts < 5) : (attempts += 1) {
            if (sb.Send(pair.client, send, 100, 0) < 0) {
                passed = run.errno() == bsd.EPIPE or run.errno() == bsd.ECONNRESET;
                break;
            }
            run.setReceiveTimeout(pair.client, 1);
            if (sb.Recv(pair.client, receive, 1, 0) < 0 and (run.errno() == bsd.ECONNRESET or run.errno() == bsd.EPIPE)) {
                passed = true;
                break;
            }
        }
        run.tap.ok(passed, "send(): error after peer closes connection [BSD 4.4]");
        if (passed) {
            run.tap.diag("  errno: %d (after %u attempt(s))", .{ run.errno(), attempts + 1 });
        } else {
            run.tap.diag("  %u attempts without error, last errno: %d", .{ attempts, run.errno() });
        }
    } else {
        run.tap.ok(false, "send(): error after peer closes connection [BSD 4.4]");
    }
    pair.close(run);
    if (run.interrupted()) return;

    // 36. Both ways at once.
    pair = Pair.open(run, 32);
    bidirectional(run, pair);
    pair.close(run);
    if (run.interrupted()) return;

    // 37. Recv of 0 bytes leaves what came.
    pair = Pair.open(run, 33);
    if (pair.ready()) {
        _run.fillPattern(send[0..10], 12);
        _ = sb.Send(pair.client, send, 10, 0);
        run.tap.diag("  recv(len=0) returned %d", .{sb.Recv(pair.server, receive, 0, 0)});
        run.setReceiveTimeout(pair.server, 2);
        const got = sb.Recv(pair.server, receive, receive.len, 0);
        run.tap.ok(got == 10 and _run.checkPattern(receive[0..10], 12) == 0, "recv(): behavior with zero-length buffer [BSD 4.4]");
    } else {
        run.tap.ok(false, "recv(): behavior with zero-length buffer [BSD 4.4]");
    }
    pair.close(run);
    if (run.interrupted()) return;

    // 38. Send of 0 bytes, then the connection still works.
    pair = Pair.open(run, 34);
    if (pair.ready()) {
        run.tap.diag("  send(len=0) returned %d", .{sb.Send(pair.client, send, 0, 0)});
        _run.fillPattern(send[0..10], 13);
        _ = sb.Send(pair.client, send, 10, 0);
        run.setReceiveTimeout(pair.server, 2);
        const got = sb.Recv(pair.server, receive, receive.len, 0);
        run.tap.ok(got == 10 and _run.checkPattern(receive[0..10], 13) == 0, "send(): zero-length send [BSD 4.4]");
    } else {
        run.tap.ok(false, "send(): zero-length send [BSD 4.4]");
    }
    pair.close(run);
    if (run.interrupted()) return;

    // 39 to 42 need the host helper.
    if (!run.helper.connected) {
        for (0..4) |_| {
            run.tap.skip("host helper not connected");
            if (run.interrupted()) return;
        }
        return;
    }

    // 39. 64 KiB echoed.
    _ = echo(run, 8, 10, "send()/recv(): 64KB TCP integrity via network [BSD 4.4]");
    if (run.interrupted()) return;

    // 40. A datagram echoed.
    networkDatagram(run);
    if (run.interrupted()) return;

    // 41. A connection the helper makes.
    incoming(run);
    if (run.interrupted()) return;

    // 42. 256 KiB echoed, and how fast.
    const started = run.now();
    const verified = echo(run, 32, 30, "send()/recv(): 256KB+ TCP integrity via network [BSD 4.4]");
    const ms = run.msSince(started);
    if (verified > 0) {
        const rate: u32 = if (ms > 0) verified / 1024 * 1000 / ms else 0;
        run.tap.diag("  ms=%u KB/s=%u", .{ ms, rate });
        run.tap.note("Network 256KB echo: %u KB/s", .{rate});
    }
}

/// A datagram of 100 bytes from one socket to another on the loopback;
/// with `churn` a stream socket is made and closed first, with `sender_too`
/// the address it came from is checked as well.
fn datagram(run: *Run, offset: u16, seed: u32, churn: bool, sender_too: bool, description: [*:0]const u8) void {
    const sb = run.sb;
    const send = &run.buffers.send;
    const receive = &run.buffers.receive;
    if (churn) run.close(run.tcpSocket());
    const from = run.udpSocket();
    const to = run.udpSocket();
    if (from >= 0 and to >= 0) {
        run.setFlag(to, bsd.SO_REUSEADDR, 1);
        const address = _run.loopback(run.port(offset));
        _ = sb.Bind(to, address.anyConst(), @sizeOf(bsd.sockaddr_in));
        _run.fillPattern(send[0..100], seed);
        _ = sb.SendTo(from, send, 100, 0, address.anyConst(), @sizeOf(bsd.sockaddr_in));
        run.setReceiveTimeout(to, 2);
        var sender: bsd.sockaddr_in = .{ .sin_family = 0 };
        var length: u32 = @sizeOf(bsd.sockaddr_in);
        const got = sb.RecvFrom(to, receive, receive.len, 0, sender.any(), &length);
        const right = got == 100 and _run.checkPattern(receive[0..100], seed) == 0;
        run.tap.ok(right and (!sender_too or sender.sin_addr.s_addr == bsd.htonl(bsd.INADDR_LOOPBACK)), description);
    } else {
        run.tap.ok(false, description);
    }
    run.close(from);
    run.close(to);
}

fn bidirectional(run: *Run, pair: Pair) void {
    const description = "send()/recv(): simultaneous bidirectional transfer [BSD 4.4]";
    const sb = run.sb;
    const send = &run.buffers.send;
    const receive = &run.buffers.receive;
    if (!pair.ready()) return run.tap.ok(false, description);
    _run.fillPattern(send[0..200], 10);
    var sent = sb.Send(pair.client, send, 200, 0);
    if (sent != 200) {
        run.tap.ok(false, description);
        return run.tap.diag("  send(client): rc=%d errno=%d", .{ sent, run.errno() });
    }
    _run.fillPattern(send[0..200], 11);
    sent = sb.Send(pair.server, send, 200, 0);
    if (sent != 200) {
        run.tap.ok(false, description);
        return run.tap.diag("  send(server): rc=%d errno=%d", .{ sent, run.errno() });
    }
    run.setReceiveTimeout(pair.server, 2);
    var total = _run.receiveAll(sb, pair.server, receive[0..200]);
    var mismatch = _run.checkPattern(receive[0..200], 10);
    if (total != 200 or mismatch != 0) {
        run.tap.ok(false, description);
        return run.tap.diag("  server recv: total=%u mismatch=%u errno=%d", .{ total, mismatch, run.errno() });
    }
    run.setReceiveTimeout(pair.client, 2);
    total = _run.receiveAll(sb, pair.client, receive[0..200]);
    mismatch = _run.checkPattern(receive[0..200], 11);
    run.tap.ok(total == 200 and mismatch == 0, description);
    if (total != 200 or mismatch != 0) run.tap.diag("  client recv: total=%u mismatch=%u errno=%d", .{ total, mismatch, run.errno() });
}

/// `blocks` blocks of 8 KiB sent to the helper's echo and checked as they
/// come back: the bytes that came back right.
fn echo(run: *Run, blocks: u32, timeout: u32, description: [*:0]const u8) u32 {
    const sb = run.sb;
    const send = &run.buffers.send;
    const receive = &run.buffers.receive;
    const descriptor = run.helper.service(run, helper.tcp_echo_port);
    if (descriptor < 0) {
        run.tap.ok(false, description);
        return 0;
    }
    defer run.close(descriptor);
    run.setReceiveTimeout(descriptor, timeout);
    _run.fillPattern(send, 0);
    var sent: u32 = 0;
    var block: u32 = 0;
    while (block < blocks) : (block += 1) {
        const got = sb.Send(descriptor, send, send.len, 0);
        if (got <= 0) break;
        sent += @intCast(got);
    }
    const wanted = blocks * send.len;
    var received: u32 = 0;
    var verified: u32 = 0;
    var filled: u32 = 0;
    while (received < wanted) {
        const got = sb.Recv(descriptor, receive[filled..].ptr, receive.len - filled, 0);
        if (got <= 0) break;
        received += @intCast(got);
        filled += @intCast(got);
        if (filled == receive.len) {
            if (_run.checkPattern(receive, 0) == 0) verified += filled;
            filled = 0;
        }
    }
    if (filled > 0 and _run.checkPattern(receive[0..filled], 0) == 0) verified += filled;
    run.tap.ok(verified >= wanted, description);
    run.tap.diag("  sent=%u recv=%u verified=%u", .{ sent, received, verified });
    return verified;
}

fn networkDatagram(run: *Run) void {
    const description = "sendto()/recvfrom(): UDP datagram via network [RFC 768]";
    const sb = run.sb;
    const send = &run.buffers.send;
    const receive = &run.buffers.receive;
    const descriptor = run.udpSocket();
    if (descriptor < 0) return run.tap.ok(false, description);
    defer run.close(descriptor);
    const to = run.helper.at(helper.udp_echo_port);
    _run.fillPattern(send[0..512], 0x55);
    var got = sb.SendTo(descriptor, send, 512, 0, to.anyConst(), @sizeOf(bsd.sockaddr_in));
    if (got != 512) {
        run.tap.ok(false, description);
        return run.tap.diag("  sendto=%d errno=%d", .{ got, run.errno() });
    }
    run.setReceiveTimeout(descriptor, 5);
    var sender: bsd.sockaddr_in = .{};
    var length: u32 = @sizeOf(bsd.sockaddr_in);
    got = sb.RecvFrom(descriptor, receive, receive.len, 0, sender.any(), &length);
    if (got != 512) {
        run.tap.ok(false, description);
        return run.tap.diag("  recv=%d errno=%d", .{ got, run.errno() });
    }
    run.tap.ok(_run.checkPattern(receive[0..512], 0x55) == 0, description);
    run.tap.diag("  sent=512 recv=%d", .{got});
}

fn incoming(run: *Run) void {
    const description = "accept(): incoming connection from remote host [BSD 4.4]";
    const greeting = "BSDSOCKTEST HELLO FROM HELPER\n";
    const sb = run.sb;
    const receive = &run.buffers.receive;
    const listener = run.tcpSocket();
    if (listener < 0) return run.tap.ok(false, description);
    defer run.close(listener);
    run.setFlag(listener, bsd.SO_REUSEADDR, 1);
    const port = run.port(161);
    const address: bsd.sockaddr_in = .{ .sin_port = bsd.htons(port), .sin_addr = .{ .s_addr = bsd.htonl(bsd.INADDR_ANY) } };
    _ = sb.Bind(listener, address.anyConst(), @sizeOf(bsd.sockaddr_in));
    _ = sb.Listen(listener, 5);
    if (!run.helper.requestConnect(run, port)) return run.tap.ok(false, description);
    if (run.waitReadable(listener, 5, 0) <= 0) return run.tap.ok(false, description);
    const accepted = sb.Accept(listener, null, null);
    if (accepted < 0) return run.tap.ok(false, description);
    defer run.close(accepted);
    run.setReceiveTimeout(accepted, 5);
    const total = _run.receiveAll(sb, accepted, receive[0..greeting.len]);
    var same = total == greeting.len;
    if (same) {
        for (greeting, receive[0..greeting.len]) |want, got| {
            if (want != got) same = false;
        }
    }
    run.tap.ok(same, description);
    if (total != greeting.len) run.tap.diag("  received %u of %u bytes", .{ total, @as(u32, greeting.len) });
}
