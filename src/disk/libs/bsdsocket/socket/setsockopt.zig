// SPDX-License-Identifier: MIT
//! SetSockOpt: one of a socket's options set.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const timer = sdk.devices.timer;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _tcp = @import("../tcp/_tcp.zig");

/// The most a socket may buffer: SO_RCVBUF and SO_SNDBUF are held to it.
const buffer_max: u32 = 256 * 1024;

/// One of the socket's options set.
///
/// SYNOPSIS:
/// ```zig
/// fn SetSockOpt(base: *SocketBase, socket: i32, level: i32, option: i32, value: *const anyopaque, value_length: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `socket` - a descriptor from Socket.
/// - `level` - `SOL_SOCKET`.
/// - `option` - `SO_REUSEADDR`, `SO_BROADCAST` (an i32, not 0 for on),
///   `SO_RCVBUF`, `SO_SNDBUF` (an i32 of bytes), `SO_RCVTIMEO`,
///   `SO_SNDTIMEO` (a timeval; zero waits for ever), `SO_EVENTMASK` (an
///   i32 of FD_* events to be told of with the event signal),
///   `SO_KEEPALIVE` (an i32, a stream socket only), `SO_LINGER` (a
///   `linger`); at level `IPPROTO_TCP`, `TCP_NODELAY` (an i32).
/// - `value` - the option's value.
/// - `value_length` - its size.
///
/// RESULT:
/// 0, or -1 with Errno(): `EBADF`, `ENOPROTOOPT` (another level or an
/// option there is not, or one that can only be read), `EINVAL` (a value
/// of the wrong size).
///
/// BEHAVIOR:
/// `SO_RCVBUF` is how many bytes of datagrams wait on the socket before
/// the next is dropped; it is held to between 1 byte and 256 KiB. On a
/// stream socket it and `SO_SNDBUF` are the sizes of its rings, from 1 KiB
/// to 64 KiB, and change only while the ring is empty (`EINVAL` else).
/// `SO_REUSEADDR` must be set before Bind to count. `SO_SNDTIMEO` is kept
/// and changes nothing for a datagram socket, which never waits to send.
/// `SO_EVENTMASK` with `FD_WRITE` tells of it at once, since a datagram
/// socket can always send.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Forbid: not held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `value` is read and not kept.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetSockOpt`, `IoctlSocket`
///
/// EXAMPLES:
/// ```zig
/// const on: i32 = 1;
/// _ = sb.SetSockOpt(socket, bsd.SOL_SOCKET, bsd.SO_BROADCAST, &on, @sizeOf(i32));
/// ```
pub fn SetSockOpt(sb: *SocketBase, descriptor: i32, level: i32, option: i32, value: *const anyopaque, value_length: u32) i32 {
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    const socket = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "SetSockOpt");
    if (level == bsd.IPPROTO_TCP and socket.socket_type == bsd.SOCK_STREAM and option == bsd.TCP_NODELAY) {
        if (value_length < @sizeOf(i32)) return _socket.fail(sb, bsd.EINVAL, "SetSockOpt");
        const tcb = _tcp.of(socket);
        if (@as(*align(1) const i32, @ptrCast(value)).* != 0) tcb.flags |= _tcp.no_delay else tcb.flags &= ~_tcp.no_delay;
        return 0;
    }
    if (level != bsd.SOL_SOCKET) return _socket.fail(sb, bsd.ENOPROTOOPT, "SetSockOpt");
    switch (option) {
        bsd.SO_LINGER => {
            if (value_length < @sizeOf(bsd.linger)) return _socket.fail(sb, bsd.EINVAL, "SetSockOpt");
            socket.linger = @as(*align(1) const bsd.linger, @ptrCast(value)).*;
        },
        bsd.SO_KEEPALIVE => {
            if (value_length < @sizeOf(i32)) return _socket.fail(sb, bsd.EINVAL, "SetSockOpt");
            if (socket.socket_type != bsd.SOCK_STREAM) return _socket.fail(sb, bsd.ENOPROTOOPT, "SetSockOpt");
            const tcb = _tcp.of(socket);
            const timers = @import("../tcp/timers.zig");
            const _timer = @import("../timer/_timer.zig");
            if (@as(*align(1) const i32, @ptrCast(value)).* != 0) {
                tcb.flags |= _tcp.keep_alive;
                timers.keepalive(sb.stack, tcb, _timer.clock(sb.stack));
            } else {
                tcb.flags &= ~_tcp.keep_alive;
                if (tcb.state != .time_wait) _timer.cancel(sb.stack, &tcb.timer_long);
            }
        },
        bsd.SO_EVENTMASK => {
            if (value_length < @sizeOf(i32)) return _socket.fail(sb, bsd.EINVAL, "SetSockOpt");
            socket.event_mask = @bitCast(@as(*align(1) const i32, @ptrCast(value)).*);
            socket.events &= socket.event_mask;
            if (_socket.writable(socket)) _socket.wake(socket, bsd.FD_WRITE);
        },
        bsd.SO_REUSEADDR, bsd.SO_BROADCAST, bsd.SO_RCVBUF, bsd.SO_SNDBUF => {
            if (value_length < @sizeOf(i32)) return _socket.fail(sb, bsd.EINVAL, "SetSockOpt");
            const number = @as(*align(1) const i32, @ptrCast(value)).*;
            switch (option) {
                bsd.SO_REUSEADDR => setFlag(socket, _socket.reuse_address, number != 0),
                bsd.SO_BROADCAST => setFlag(socket, _socket.broadcast_allowed, number != 0),
                bsd.SO_RCVBUF, bsd.SO_SNDBUF => {
                    const bytes = bytesOf(number);
                    if (socket.socket_type == bsd.SOCK_STREAM) {
                        // A stream's buffer is its ring, made anew while
                        // it is empty.
                        const tcb = _tcp.of(socket);
                        const ring = if (option == bsd.SO_RCVBUF) &tcb.receive else &tcb.send;
                        if (!_tcp.resize(sb.stack, ring, bytes)) return _socket.fail(sb, bsd.EINVAL, "SetSockOpt");
                    }
                    if (option == bsd.SO_RCVBUF) socket.receive_limit = bytes else socket.send_limit = bytes;
                },
                else => {},
            }
        },
        bsd.SO_RCVTIMEO, bsd.SO_SNDTIMEO => {
            if (value_length < @sizeOf(timer.TimeVal)) return _socket.fail(sb, bsd.EINVAL, "SetSockOpt");
            const time = @as(*align(1) const timer.TimeVal, @ptrCast(value)).*;
            if (option == bsd.SO_RCVTIMEO) socket.receive_timeout = time else socket.send_timeout = time;
        },
        else => return _socket.fail(sb, bsd.ENOPROTOOPT, "SetSockOpt"),
    }
    return 0;
}

fn setFlag(socket: *_socket.Socket, flag: u32, on: bool) void {
    if (on) socket.flags |= flag else socket.flags &= ~flag;
}

fn bytesOf(number: i32) u32 {
    if (number < 1) return 1;
    const bytes: u32 = @intCast(number);
    return @min(bytes, buffer_max);
}
