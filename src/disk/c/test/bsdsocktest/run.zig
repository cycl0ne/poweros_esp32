// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Thomas Dye
//! What every category works with: the libraries, the results, the host
//! helper, the buffers, and the small steps the tests are built of - a
//! loopback listener and a client connected to it, a descriptor closed
//! if it is one, a test pattern and its check, the time in microseconds.
//!
//! Each category takes its ports from the base port (PORT, 7700) plus
//! offsets of its own, so no test finds one another left behind.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const TimerBase = sdk.interface.timer.TimerBase;
const Tap = @import("tap.zig").Tap;
const Helper = @import("helper.zig").Helper;

/// The port the tests count from, unless PORT gives another.
pub const default_base_port: u16 = 7700;

/// The buffers the tests send from and receive into, allocated once:
/// too large for a command's stack.
pub const Buffers = struct {
    send: [8192]u8,
    receive: [8192]u8,
    descriptors: [256]i32,
    icmp_send: [1500]u8,
    icmp_receive: [1500]u8,
};

pub const Run = struct {
    sys: *ExecBase,
    dl: *DosBase,
    sb: *SocketBase,
    timer_base: *TimerBase,
    tap: Tap,
    helper: Helper = .{},
    base_port: u16 = default_base_port,
    buffers: *Buffers,

    /// The error number of the last call that failed.
    pub fn errno(run: *Run) i32 {
        return run.sb.Errno();
    }

    /// Why the last name lookup failed.
    pub fn hErrno(run: *Run) i32 {
        var value: u32 = 0;
        const tags = [_]sdk.utility.TagItem{
            .{ .tag = bsd.SBTM_GETREF(bsd.SBTC_HERRNO), .data = @intFromPtr(&value) },
            .{},
        };
        _ = run.sb.SocketBaseTagList(&tags);
        return @bitCast(value);
    }

    /// One SBTM_GETREF tag's value; 0 when the library has no such code.
    pub fn getTag(run: *Run, code: u32) u32 {
        var value: u32 = 0;
        const tags = [_]sdk.utility.TagItem{
            .{ .tag = bsd.SBTM_GETREF(code), .data = @intFromPtr(&value) },
            .{},
        };
        _ = run.sb.SocketBaseTagList(&tags);
        return value;
    }

    /// One SBTM_SETVAL tag: true when the library took it.
    pub fn setTag(run: *Run, code: u32, value: u32) bool {
        const tags = [_]sdk.utility.TagItem{
            .{ .tag = bsd.SBTM_SETVAL(code), .data = value },
            .{},
        };
        return run.sb.SocketBaseTagList(&tags) == 0;
    }

    /// Ctrl-C since the last look: the run given up.
    pub fn interrupted(run: *Run) bool {
        if (run.sys.SetSignal(0, exec.SIGBREAKF_CTRL_C) & exec.SIGBREAKF_CTRL_C == 0) return false;
        run.tap.bail("Interrupted by Ctrl-C");
        return true;
    }

    /// The base port plus `offset`.
    pub fn port(run: *Run, offset: u16) u16 {
        return run.base_port + offset;
    }

    pub fn tcpSocket(run: *Run) i32 {
        return run.sb.Socket(bsd.AF_INET, bsd.SOCK_STREAM, 0);
    }

    pub fn udpSocket(run: *Run) i32 {
        return run.sb.Socket(bsd.AF_INET, bsd.SOCK_DGRAM, 0);
    }

    /// A stream listener on 127.0.0.1 at `at`, with SO_REUSEADDR and a
    /// queue of 5: its descriptor, or -1.
    pub fn loopbackListener(run: *Run, at: u16) i32 {
        const descriptor = run.tcpSocket();
        if (descriptor < 0) return -1;
        run.setFlag(descriptor, bsd.SO_REUSEADDR, 1);
        const address = loopback(at);
        if (run.sb.Bind(descriptor, address.anyConst(), @sizeOf(bsd.sockaddr_in)) < 0 or
            run.sb.Listen(descriptor, 5) < 0)
        {
            _ = run.sb.CloseSocket(descriptor);
            return -1;
        }
        return descriptor;
    }

    /// A stream socket connected to 127.0.0.1 at `at`: its descriptor,
    /// or -1.
    pub fn loopbackClient(run: *Run, at: u16) i32 {
        const descriptor = run.tcpSocket();
        if (descriptor < 0) return -1;
        const address = loopback(at);
        if (run.sb.Connect(descriptor, address.anyConst(), @sizeOf(bsd.sockaddr_in)) < 0) {
            _ = run.sb.CloseSocket(descriptor);
            return -1;
        }
        return descriptor;
    }

    /// The next connection on `listener`: its descriptor, or -1.
    pub fn acceptOne(run: *Run, listener: i32) i32 {
        var address: bsd.sockaddr_in = .{};
        var length: u32 = @sizeOf(bsd.sockaddr_in);
        return run.sb.Accept(listener, address.any(), &length);
    }

    /// An i32 option at SOL_SOCKET set.
    pub fn setFlag(run: *Run, descriptor: i32, option: i32, value: i32) void {
        _ = run.sb.SetSockOpt(descriptor, bsd.SOL_SOCKET, option, &value, @sizeOf(i32));
    }

    /// The socket's calls made never to wait: 0, or -1.
    pub fn setNonblocking(run: *Run, descriptor: i32) i32 {
        var never: i32 = 1;
        return run.sb.IoctlSocket(descriptor, bsd.FIONBIO, &never);
    }

    /// SO_RCVTIMEO of `seconds`.
    pub fn setReceiveTimeout(run: *Run, descriptor: i32, seconds: u32) void {
        const time: bsd.timeval = .{ .secs = seconds, .micro = 0 };
        _ = run.sb.SetSockOpt(descriptor, bsd.SOL_SOCKET, bsd.SO_RCVTIMEO, &time, @sizeOf(bsd.timeval));
    }

    /// The socket closed, if `descriptor` is one.
    pub fn close(run: *Run, descriptor: i32) void {
        if (descriptor >= 0) _ = run.sb.CloseSocket(descriptor);
    }

    /// Each socket closed and its entry set to -1.
    pub fn closeAll(run: *Run, descriptors: []i32) void {
        for (descriptors) |*descriptor| {
            run.close(descriptor.*);
            descriptor.* = -1;
        }
    }

    /// Microseconds of system time.
    pub fn now(run: *Run) u64 {
        var time: timer.TimeVal = .{};
        run.timer_base.GetSysTime(&time);
        return time.toMicros();
    }

    /// Milliseconds since `start`, rounded.
    pub fn msSince(run: *Run, start: u64) u32 {
        return @intCast((run.now() - start + 500) / 1000);
    }

    /// A readiness wait on `descriptor` alone: WaitSelect's answer.
    pub fn waitReadable(run: *Run, descriptor: i32, seconds: u32, micros: u32) i32 {
        var read: bsd.fd_set = .{};
        read.set(descriptor);
        var time: bsd.timeval = .{ .secs = seconds, .micro = micros };
        return run.sb.WaitSelect(descriptor + 1, &read, null, null, &time, null);
    }

    /// WaitSelect on nothing: a delay.
    pub fn delay(run: *Run, seconds: u32, micros: u32) void {
        var time: bsd.timeval = .{ .secs = seconds, .micro = micros };
        _ = run.sb.WaitSelect(0, null, null, null, &time, null);
    }

    /// A signal of the task's own: its number, or -1.
    pub fn allocSignal(run: *Run) i8 {
        return run.sys.AllocSignal(-1);
    }

    pub fn freeSignal(run: *Run, signal: i8) void {
        if (signal >= 0) run.sys.FreeSignal(signal);
    }
};

/// A connected pair on the loopback, and its listener: the client and
/// the server end, each -1 when it could not be made.
pub const Pair = struct {
    listener: i32,
    client: i32,
    server: i32,

    pub fn open(run: *Run, offset: u16) Pair {
        const port = run.port(offset);
        const listener = run.loopbackListener(port);
        const client = run.loopbackClient(port);
        return .{ .listener = listener, .client = client, .server = run.acceptOne(listener) };
    }

    pub fn ready(pair: Pair) bool {
        return pair.client >= 0 and pair.server >= 0;
    }

    pub fn close(pair: Pair, run: *Run) void {
        run.close(pair.server);
        run.close(pair.client);
        run.close(pair.listener);
    }
};

/// 127.0.0.1 at `at`.
pub fn loopback(at: u16) bsd.sockaddr_in {
    return .{ .sin_port = bsd.htons(at), .sin_addr = .{ .s_addr = bsd.htonl(bsd.INADDR_LOOPBACK) } };
}

/// `bytes` filled with the pattern `seed` starts: each byte bits 16 to 23
/// of the next step of a linear congruential generator. The host helper
/// makes the same.
pub fn fillPattern(bytes: []u8, seed: u32) void {
    var state = seed;
    for (bytes) |*byte| {
        state = state *% 1103515245 +% 12345;
        byte.* = @truncate(state >> 16);
    }
}

/// 0 when `bytes` hold the pattern `seed` starts, else the place of the
/// first that does not, from 1.
pub fn checkPattern(bytes: []const u8, seed: u32) u32 {
    var state = seed;
    for (bytes, 1..) |byte, place| {
        state = state *% 1103515245 +% 12345;
        if (byte != @as(u8, @truncate(state >> 16))) return @intCast(place);
    }
    return 0;
}

/// Receive into `bytes` until they are full, the peer closes, or a
/// receive fails: how many came.
pub fn receiveAll(sb: *SocketBase, descriptor: i32, bytes: []u8) u32 {
    var total: u32 = 0;
    while (total < bytes.len) {
        const got = sb.Recv(descriptor, bytes[total..].ptr, @intCast(bytes.len - total), 0);
        if (got <= 0) break;
        total += @intCast(got);
    }
    return total;
}
