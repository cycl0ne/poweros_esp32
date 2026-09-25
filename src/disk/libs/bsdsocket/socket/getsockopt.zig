// SPDX-License-Identifier: MIT
//! GetSockOpt: one of a socket's options read.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const timer = sdk.devices.timer;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _tcp = @import("../tcp/_tcp.zig");

/// One of the socket's options read into `value`.
///
/// SYNOPSIS:
/// ```zig
/// fn GetSockOpt(base: *SocketBase, socket: i32, level: i32, option: i32, value: *anyopaque, value_length: *u32) i32
/// ```
///
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// - `socket` - a descriptor from Socket.
/// - `level` - `SOL_SOCKET`.
/// - `option` - any SetSockOpt takes, and `SO_ERROR` (the socket's
///   pending error, which reading clears) and `SO_TYPE` (its SOCK_*), each
///   an i32.
/// - `value` - where the value goes.
/// - `value_length` - in, the room at `value`; out, the value's size.
///
/// RESULT:
/// 0, or -1 with Errno(): `EBADF`, `ENOPROTOOPT`, `EINVAL` (too little
/// room).
///
/// BEHAVIOR:
/// The flags answer 1 or 0.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Forbid: not held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetSockOpt`
///
/// EXAMPLES:
/// ```zig
/// var pending: i32 = 0;
/// var size: u32 = @sizeOf(i32);
/// _ = sb.GetSockOpt(socket, bsd.SOL_SOCKET, bsd.SO_ERROR, &pending, &size);
/// ```
pub fn GetSockOpt(sb: *SocketBase, descriptor: i32, level: i32, option: i32, value: *anyopaque, value_length: *u32) i32 {
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    const socket = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "GetSockOpt");
    if (level == bsd.IPPROTO_TCP and socket.socket_type == bsd.SOCK_STREAM and option == bsd.TCP_NODELAY) {
        if (value_length.* < @sizeOf(i32)) return _socket.fail(sb, bsd.EINVAL, "GetSockOpt");
        @as(*align(1) i32, @ptrCast(value)).* = @intFromBool(_tcp.of(socket).flags & _tcp.no_delay != 0);
        value_length.* = @sizeOf(i32);
        return 0;
    }
    if (level != bsd.SOL_SOCKET) return _socket.fail(sb, bsd.ENOPROTOOPT, "GetSockOpt");
    switch (option) {
        bsd.SO_LINGER => {
            if (value_length.* < @sizeOf(bsd.linger)) return _socket.fail(sb, bsd.EINVAL, "GetSockOpt");
            @as(*align(1) bsd.linger, @ptrCast(value)).* = socket.linger;
            value_length.* = @sizeOf(bsd.linger);
            return 0;
        },
        bsd.SO_RCVTIMEO, bsd.SO_SNDTIMEO => {
            if (value_length.* < @sizeOf(timer.TimeVal)) return _socket.fail(sb, bsd.EINVAL, "GetSockOpt");
            @as(*align(1) timer.TimeVal, @ptrCast(value)).* = if (option == bsd.SO_RCVTIMEO) socket.receive_timeout else socket.send_timeout;
            value_length.* = @sizeOf(timer.TimeVal);
            return 0;
        },
        else => {},
    }
    if (value_length.* < @sizeOf(i32)) return _socket.fail(sb, bsd.EINVAL, "GetSockOpt");
    const number: i32 = switch (option) {
        bsd.SO_REUSEADDR => @intFromBool(socket.flags & _socket.reuse_address != 0),
        bsd.SO_BROADCAST => @intFromBool(socket.flags & _socket.broadcast_allowed != 0),
        bsd.SO_RCVBUF => @intCast(socket.receive_limit),
        bsd.SO_SNDBUF => @intCast(socket.send_limit),
        bsd.SO_TYPE => socket.socket_type,
        bsd.SO_EVENTMASK => @bitCast(socket.event_mask),
        bsd.SO_KEEPALIVE => if (socket.socket_type == bsd.SOCK_STREAM) @intFromBool(_tcp.of(socket).flags & _tcp.keep_alive != 0) else 0,
        bsd.SO_ERROR => blk: {
            const pending = socket.pending_error;
            socket.pending_error = 0;
            break :blk pending;
        },
        else => return _socket.fail(sb, bsd.ENOPROTOOPT, "GetSockOpt"),
    };
    @as(*align(1) i32, @ptrCast(value)).* = number;
    value_length.* = @sizeOf(i32);
    return 0;
}
