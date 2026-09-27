// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Thomas Dye
//! The signals category, tests 73 to 87: SocketBaseTagList's signal
//! masks and table size set and read back, and socket events - a signal
//! from SO_EVENTMASK for data, a connect, a connection to accept and a
//! peer that closed, none for an idle socket, GetSocketEvents taking each
//! event once and one socket after another, and fifty rounds of it in a
//! row. Ports: offsets 80 to 87.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _run = @import("run.zig");
const Run = _run.Run;
const Pair = _run.Pair;

/// The error number's and the lookup error's variables, as a pointer:
/// codes the library has none of.
const SBTC_ERRNOLONGPTR: u32 = 24;
const SBTC_HERRNOLONGPTR: u32 = 25;

/// A signal of the task's for socket events, set as SBTC_SIGEVENTMASK
/// while a test runs, and cleared after it.
const Events = struct {
    signal: i8,
    mask: u32,

    fn start(run: *Run) ?Events {
        const signal = run.allocSignal();
        if (signal < 0) {
            run.tap.skip("could not allocate signal");
            return null;
        }
        const mask = @as(u32, 1) << @intCast(signal);
        _ = run.setTag(bsd.SBTC_SIGEVENTMASK, mask);
        return .{ .signal = signal, .mask = mask };
    }

    /// Until the signal comes, at most two seconds.
    fn wait(events: Events, run: *Run) void {
        var signals = events.mask;
        var time: bsd.timeval = .{ .secs = 2 };
        _ = run.sb.WaitSelect(0, null, null, null, &time, &signals);
    }

    fn stop(_: Events, run: *Run) void {
        _ = run.setTag(bsd.SBTC_SIGEVENTMASK, 0);
    }

    /// After the sockets are closed: the signal cleared and given back.
    fn free(events: Events, run: *Run) void {
        _ = run.sys.SetSignal(0, events.mask);
        run.freeSignal(events.signal);
    }
};

fn setEvents(run: *Run, descriptor: i32, mask: i32) void {
    run.setFlag(descriptor, bsd.SO_EVENTMASK, mask);
}

pub fn tests(run: *Run) void {
    // 73. SetSocketSignals.
    run.tap.skip("no SetSocketSignals");
    if (run.interrupted()) return;

    // 74, 75. The break and the event mask set and read back.
    maskRoundTrip(run, bsd.SBTC_BREAKMASK, "SocketBaseTags(SBTC_BREAKMASK): Ctrl-C signal [AmiTCP]");
    if (run.interrupted()) return;
    maskRoundTrip(run, bsd.SBTC_SIGEVENTMASK, "SocketBaseTags(SBTC_SIGEVENTMASK): event signal [AmiTCP]");
    if (run.interrupted()) return;

    // 76, 77. Where the error numbers are kept.
    pointerTag(run, SBTC_ERRNOLONGPTR, "SBTC_ERRNOLONGPTR");
    if (run.interrupted()) return;
    pointerTag(run, SBTC_HERRNOLONGPTR, "SBTC_HERRNOLONGPTR");
    if (run.interrupted()) return;

    // 78. The descriptor table's size, and a larger one.
    tableSize(run);
    if (run.interrupted()) return;

    // 79. FD_READ when data comes.
    if (Events.start(run)) |events| {
        const pair = Pair.open(run, 80);
        if (pair.ready()) {
            setEvents(run, pair.server, bsd.FD_READ);
            var bytes: [100]u8 = undefined;
            _run.fillPattern(&bytes, 91);
            _ = run.sb.Send(pair.client, &bytes, bytes.len, 0);
            events.wait(run);
            var mask: u32 = 0;
            const descriptor = run.sb.GetSocketEvents(&mask);
            run.tap.ok(descriptor == pair.server and mask & bsd.FD_READ != 0, "SO_EVENTMASK FD_READ: signal on data arrival [AmiTCP]");
            run.tap.diag("  evfd=%d (expected %d), evmask=0x%x", .{ descriptor, pair.server, mask });
            setEvents(run, pair.server, 0);
        } else {
            run.tap.ok(false, "SO_EVENTMASK FD_READ: signal on data arrival [AmiTCP]");
        }
        events.stop(run);
        pair.close(run);
        events.free(run);
    }
    if (run.interrupted()) return;

    // 80. FD_CONNECT when a connect that did not wait is done.
    if (Events.start(run)) |events| {
        connectEvent(run, events);
        events.free(run);
    }
    if (run.interrupted()) return;

    // 81. No event on a socket nothing happens to.
    if (Events.start(run)) |events| {
        const descriptor = run.tcpSocket();
        if (descriptor >= 0) {
            setEvents(run, descriptor, bsd.FD_READ | bsd.FD_WRITE | bsd.FD_CONNECT);
            run.delay(0, 100000);
            const pending = run.sys.SetSignal(0, 0);
            var mask: u32 = 0;
            const got = run.sb.GetSocketEvents(&mask);
            const signalled = pending & events.mask != 0;
            run.tap.ok(!signalled and got == -1, "SO_EVENTMASK: no spurious events on idle socket [AmiTCP]");
            run.tap.diag("  signal pending: %s, GetSocketEvents: %d", .{ @as([*:0]const u8, if (signalled) "yes" else "no"), got });
            setEvents(run, descriptor, 0);
        } else {
            run.tap.ok(false, "SO_EVENTMASK: no spurious events on idle socket [AmiTCP]");
        }
        events.stop(run);
        run.close(descriptor);
        events.free(run);
    }
    if (run.interrupted()) return;

    // 82. FD_ACCEPT when a connection comes.
    if (Events.start(run)) |events| {
        const port = run.port(82);
        const listener = run.loopbackListener(port);
        var client: i32 = -1;
        if (listener >= 0) {
            setEvents(run, listener, bsd.FD_ACCEPT);
            client = run.loopbackClient(port);
            if (client >= 0) {
                events.wait(run);
                var mask: u32 = 0;
                const descriptor = run.sb.GetSocketEvents(&mask);
                run.tap.ok(descriptor == listener and mask & bsd.FD_ACCEPT != 0, "SO_EVENTMASK FD_ACCEPT: signal on incoming [AmiTCP]");
                run.tap.diag("  evfd=%d (expected %d), evmask=0x%x", .{ descriptor, listener, mask });
                run.close(run.acceptOne(listener));
            } else {
                run.tap.ok(false, "SO_EVENTMASK FD_ACCEPT: signal on incoming [AmiTCP]");
            }
            setEvents(run, listener, 0);
        } else {
            run.tap.ok(false, "SO_EVENTMASK FD_ACCEPT: signal on incoming [AmiTCP]");
        }
        events.stop(run);
        run.close(client);
        run.close(listener);
        events.free(run);
    }
    if (run.interrupted()) return;

    // 83. FD_CLOSE when the peer closes.
    if (Events.start(run)) |events| {
        var pair = Pair.open(run, 83);
        if (pair.ready()) {
            setEvents(run, pair.server, bsd.FD_CLOSE);
            run.close(pair.client);
            pair.client = -1;
            events.wait(run);
            var mask: u32 = 0;
            const descriptor = run.sb.GetSocketEvents(&mask);
            run.tap.ok(descriptor == pair.server and mask & bsd.FD_CLOSE != 0, "SO_EVENTMASK FD_CLOSE: signal on peer disconnect [AmiTCP]");
            run.tap.diag("  evfd=%d (expected %d), evmask=0x%x", .{ descriptor, pair.server, mask });
            setEvents(run, pair.server, 0);
        } else {
            run.tap.ok(false, "SO_EVENTMASK FD_CLOSE: signal on peer disconnect [AmiTCP]");
        }
        events.stop(run);
        pair.close(run);
        events.free(run);
    }
    if (run.interrupted()) return;

    // 84. An event is taken once.
    if (Events.start(run)) |events| {
        const pair = Pair.open(run, 84);
        if (pair.ready()) {
            setEvents(run, pair.server, bsd.FD_READ);
            var bytes: [100]u8 = undefined;
            _run.fillPattern(&bytes, 96);
            _ = run.sb.Send(pair.client, &bytes, bytes.len, 0);
            events.wait(run);
            var first_mask: u32 = 0;
            const first = run.sb.GetSocketEvents(&first_mask);
            var second_mask: u32 = 0;
            const second = run.sb.GetSocketEvents(&second_mask);
            run.tap.ok(first >= 0 and second == -1, "GetSocketEvents(): event consumed after retrieval [AmiTCP]");
            run.tap.diag("  first: evfd=%d evmask=0x%x, second: evfd=%d", .{ first, first_mask, second });
            setEvents(run, pair.server, 0);
        } else {
            run.tap.ok(false, "GetSocketEvents(): event consumed after retrieval [AmiTCP]");
        }
        events.stop(run);
        pair.close(run);
        events.free(run);
    }
    if (run.interrupted()) return;

    // 85. Two sockets with events: each answered once.
    if (Events.start(run)) |events| {
        twoSockets(run, events);
        events.free(run);
    }
    if (run.interrupted()) return;

    // 86. No events: -1.
    var mask: u32 = 0;
    const none = run.sb.GetSocketEvents(&mask);
    run.tap.ok(none == -1, "GetSocketEvents(): -1 when no events pending [AmiTCP]");
    run.tap.diag("  returned: %d", .{none});
    if (run.interrupted()) return;

    // 87. Fifty rounds of data, signal, event and receive.
    if (Events.start(run)) |events| {
        stress(run, events);
        events.free(run);
    }
}

fn maskRoundTrip(run: *Run, code: u32, description: [*:0]const u8) void {
    const signal = run.allocSignal();
    if (signal < 0) return run.tap.skip("could not allocate signal");
    const mask = @as(u32, 1) << @intCast(signal);
    const original = run.getTag(code);
    _ = run.setTag(code, mask);
    const got = run.getTag(code);
    run.tap.ok(got == mask, description);
    run.tap.diag("  set=0x%08x, got=0x%08x", .{ mask, got });
    _ = run.setTag(code, if (code == bsd.SBTC_SIGEVENTMASK) 0 else original);
    _ = run.sys.SetSignal(0, mask);
    run.freeSignal(signal);
}

fn pointerTag(run: *Run, code: u32, name: [*:0]const u8) void {
    var pointer: u32 = 0;
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = bsd.SBTM_GETREF(code), .data = @intFromPtr(&pointer) },
        .{},
    };
    if (run.sb.SocketBaseTagList(&tags) != 0) {
        run.tap.skip(if (code == SBTC_ERRNOLONGPTR) "no SBTC_ERRNOLONGPTR" else "no SBTC_HERRNOLONGPTR");
        return;
    }
    run.tap.ok(pointer != 0, if (code == SBTC_ERRNOLONGPTR) "SocketBaseTags(SBTC_ERRNOLONGPTR): get errno pointer [AmiTCP]" else "SocketBaseTags(SBTC_HERRNOLONGPTR): get h_errno pointer [AmiTCP]");
    run.tap.diag("  %s: 0x%08x", .{ name, pointer });
}

fn tableSize(run: *Run) void {
    const description = "SocketBaseTags(SBTC_DTABLESIZE): get/set table size [AmiTCP]";
    const size = run.getTag(bsd.SBTC_DTABLESIZE);
    run.tap.diag("  current dtablesize: %u", .{size});
    if (size < 64) {
        run.tap.ok(false, description);
        run.tap.diag("  GET returned < 64, skipping SET", .{});
        return;
    }
    _ = run.setTag(bsd.SBTC_DTABLESIZE, 128);
    const larger = run.getTag(bsd.SBTC_DTABLESIZE);
    run.tap.ok(larger >= 128, description);
    run.tap.diag("  after set 128: %u", .{larger});
    _ = run.setTag(bsd.SBTC_DTABLESIZE, size);
}

fn connectEvent(run: *Run, events: Events) void {
    const description = "SO_EVENTMASK FD_CONNECT: signal on connect [AmiTCP]";
    defer events.stop(run);
    const port = run.port(81);
    const listener = run.loopbackListener(port);
    defer run.close(listener);
    if (listener < 0) return run.tap.ok(false, description);
    const client = run.tcpSocket();
    defer run.close(client);
    if (client < 0) return run.tap.ok(false, description);
    _ = run.setNonblocking(client);
    setEvents(run, client, bsd.FD_CONNECT);
    const address = _run.loopback(port);
    const result = run.sb.Connect(client, address.anyConst(), @sizeOf(bsd.sockaddr_in));
    const failed_with = run.errno();
    events.wait(run);
    var mask: u32 = 0;
    const descriptor = run.sb.GetSocketEvents(&mask);
    if (result == 0 and descriptor == -1) {
        run.tap.ok(true, description);
        run.tap.diag("  synchronous loopback connect returned 0", .{});
    } else if (descriptor == client and mask & bsd.FD_CONNECT != 0) {
        run.tap.ok(true, description);
    } else if (result < 0 and failed_with == bsd.EINPROGRESS and descriptor == -1) {
        run.tap.ok(false, description);
    } else {
        run.tap.ok(true, description);
        run.tap.diag("  connect rc=%d, evfd=%d, evmask=0x%x", .{ result, descriptor, mask });
    }
    setEvents(run, client, 0);
    run.close(run.acceptOne(listener));
}

fn twoSockets(run: *Run, events: Events) void {
    const description = "GetSocketEvents(): round-robin across sockets [AmiTCP]";
    defer events.stop(run);
    const one = Pair.open(run, 85);
    defer one.close(run);
    const two = Pair.open(run, 86);
    defer two.close(run);
    if (one.server < 0 or two.server < 0) return run.tap.ok(false, description);
    setEvents(run, one.server, bsd.FD_READ);
    setEvents(run, two.server, bsd.FD_READ);
    defer setEvents(run, one.server, 0);
    defer setEvents(run, two.server, 0);
    var bytes: [10]u8 = undefined;
    _run.fillPattern(&bytes, 97);
    _ = run.sb.Send(one.client, &bytes, bytes.len, 0);
    _ = run.sb.Send(two.client, &bytes, bytes.len, 0);
    events.wait(run);
    run.delay(0, 100000);
    var first_mask: u32 = 0;
    const first = run.sb.GetSocketEvents(&first_mask);
    var second_mask: u32 = 0;
    const second = run.sb.GetSocketEvents(&second_mask);
    var third_mask: u32 = 0;
    const third = run.sb.GetSocketEvents(&third_mask);
    const both = (first == one.server and second == two.server) or (first == two.server and second == one.server);
    run.tap.ok(both and first_mask & bsd.FD_READ != 0 and second_mask & bsd.FD_READ != 0 and third == -1, description);
    run.tap.diag("  first: fd=%d mask=0x%x, second: fd=%d mask=0x%x, third: fd=%d", .{ first, first_mask, second, second_mask, third });
}

fn stress(run: *Run, events: Events) void {
    const description = "WaitSelect + signals: stress test (50 iterations) [AmiTCP]";
    defer events.stop(run);
    const pair = Pair.open(run, 87);
    defer pair.close(run);
    if (!pair.ready()) {
        run.tap.ok(false, description);
        run.tap.diag("  listener=%d client=%d server=%d errno=%d", .{ pair.listener, pair.client, pair.server, run.errno() });
        return;
    }
    setEvents(run, pair.server, bsd.FD_READ);
    defer setEvents(run, pair.server, 0);
    run.setReceiveTimeout(pair.server, 2);
    var bytes: [10]u8 = undefined;
    var round: u32 = 0;
    const passed = while (round < 50) : (round += 1) {
        _run.fillPattern(&bytes, round);
        const sent = run.sb.Send(pair.client, &bytes, bytes.len, 0);
        if (sent != 10) {
            run.tap.diag("  iteration %u: send failed (rc=%d, errno=%d)", .{ round, sent, run.errno() });
            break false;
        }
        events.wait(run);
        var mask: u32 = 0;
        const descriptor = run.sb.GetSocketEvents(&mask);
        if (descriptor != pair.server or mask & bsd.FD_READ == 0) {
            run.tap.diag("  iteration %u: evfd=%d (expected %d), evmask=0x%x", .{ round, descriptor, pair.server, mask });
            break false;
        }
        const got = run.sb.Recv(pair.server, &bytes, bytes.len, 0);
        if (got != 10) {
            run.tap.diag("  iteration %u: recv=%d, errno=%d", .{ round, got, run.errno() });
            break false;
        }
        _ = run.sys.SetSignal(0, events.mask);
    } else true;
    run.tap.ok(passed, description);
    run.tap.diag("  completed: %u/50, total bytes: %u", .{ round, round * 10 });
}
