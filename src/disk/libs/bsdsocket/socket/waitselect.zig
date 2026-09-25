// SPDX-License-Identifier: MIT
//! WaitSelect: waiting for sockets and signals at once.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const timer = sdk.devices.timer;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");

/// Until a socket in the sets is ready, one of the caller's own signals
/// comes, or the timeout passes.
///
/// SYNOPSIS:
/// ```zig
/// fn WaitSelect(base: *SocketBase, count: i32, read: ?*fd_set, write: ?*fd_set, except: ?*fd_set,
///     timeout: ?*TimeVal, signals: ?*u32) i32
/// ```
///
/// SINCE: 1.0. LVO -72.
///
/// INPUTS:
/// - `count` - one more than the highest descriptor in any set.
/// - `read` - the sockets to wait for until a receive would not wait, or
///   null.
/// - `write` - until a send would not wait, or null.
/// - `except` - until something exceptional comes, or null.
/// - `timeout` - how long to wait at most; zero only looks; null waits
///   for ever.
/// - `signals` - in, the caller's own signals that end the wait too; out,
///   the ones of them that came. Null for none.
///
/// RESULT:
/// How many sockets are ready - the sets then hold only those - or 0
/// when the timeout passed or one of `signals` came - the sets are then
/// empty - or -1 with Errno(): `EBADF` (a descriptor in a set that is no
/// socket), `EINVAL` (`count` below 0 or past the table), `EINTR` (a break
/// signal came, and was taken).
///
/// BEHAVIOR:
/// A datagram socket is always ready to send, and ready to receive once a
/// datagram or an error waits on it. Nothing is exceptional for a
/// datagram socket, so `except` only ever comes back empty. The wait is on
/// the opener's readiness signal, the break signals, the timer and
/// `*signals` together, and the sets are looked at afresh after each: the
/// program waits on its sockets and on its windows' ports in one call.
///
/// CONTEXT:
/// - Waits: yes, unless something is ready or the timeout is zero.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do; the one that opened the base.
///
/// OWNERSHIP:
/// The sets are the caller's; they are overwritten with the answer.
///
/// NOTES:
/// The signals in `*signals` that came are taken, as Wait takes them.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RecvFrom`, `IoctlSocket`, exec's `Wait`
///
/// EXAMPLES:
/// ```zig
/// var read: bsd.fd_set = .{};
/// read.set(socket);
/// var signals: u32 = window_port.sigMask();
/// var patience: bsd.timeval = .{ .secs = 2 };
/// const ready = sb.WaitSelect(socket + 1, &read, null, null, &patience, &signals);
/// ```
pub fn WaitSelect(sb: *SocketBase, count: i32, read: ?*bsd.fd_set, write: ?*bsd.fd_set, except: ?*bsd.fd_set, timeout: ?*timer.TimeVal, signals: ?*u32) i32 {
    const sys = sb.sys_base;
    if (count < 0 or count > @as(i32, @intCast(@min(sb.table_size, bsd.FD_SETSIZE)))) return _socket.fail(sb, bsd.EINVAL, "WaitSelect");
    const wanted: u32 = if (signals) |mask| mask.* else 0;
    // The timer is stopped after the lock is let go: stopping it waits
    // for its request to come back.
    defer _socket.stopTimer(sb);
    var held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    _ = sys.SetSignal(0, sb.ready_mask);
    while (true) {
        var ready_read: bsd.fd_set = .{};
        var ready_write: bsd.fd_set = .{};
        var ready: i32 = 0;
        var descriptor: i32 = 0;
        while (descriptor < count) : (descriptor += 1) {
            const in_read = if (read) |set| set.isSet(descriptor) else false;
            const in_write = if (write) |set| set.isSet(descriptor) else false;
            const in_except = if (except) |set| set.isSet(descriptor) else false;
            if (!in_read and !in_write and !in_except) continue;
            const socket = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "WaitSelect");
            if (in_read and _socket.readable(socket)) {
                ready_read.set(descriptor);
                ready += 1;
            }
            if (in_write and _socket.writable(socket)) {
                ready_write.set(descriptor);
                ready += 1;
            }
        }
        const done = ready > 0 or (timeout != null and _socket.isZero(timeout.?.*));
        if (done) {
            answer(read, &ready_read, write, &ready_write, except);
            if (signals) |mask| mask.* = 0;
            return ready;
        }
        if (timeout) |time| {
            if (sb.timer_armed == 0) _ = _socket.startTimer(sb, time.*);
        }
        var came: u32 = 0;
        switch (_socket.wait(sb, &held, wanted, &came)) {
            .broken => return _socket.fail(sb, bsd.EINTR, "WaitSelect"),
            .signalled, .timed_out => {
                const empty: bsd.fd_set = .{};
                answer(read, &empty, write, &empty, except);
                if (signals) |mask| mask.* = came;
                return 0;
            },
            .changed => {},
        }
    }
}

fn answer(read: ?*bsd.fd_set, ready_read: *const bsd.fd_set, write: ?*bsd.fd_set, ready_write: *const bsd.fd_set, except: ?*bsd.fd_set) void {
    if (read) |set| set.* = ready_read.*;
    if (write) |set| set.* = ready_write.*;
    if (except) |set| set.zero();
}
