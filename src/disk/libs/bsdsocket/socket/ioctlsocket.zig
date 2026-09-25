// SPDX-License-Identifier: MIT
//! IoctlSocket: whether a socket waits, and what it has waiting.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _tcp = @import("../tcp/_tcp.zig");

/// A socket's control requests.
///
/// SYNOPSIS:
/// ```zig
/// fn IoctlSocket(base: *SocketBase, socket: i32, request: u32, argument: *anyopaque) i32
/// ```
///
/// SINCE: 1.0. LVO -64.
///
/// INPUTS:
/// - `socket` - a descriptor from Socket.
/// - `request` - `FIONBIO`: `argument` is an i32, not 0 for a socket
///   whose calls never wait, 0 for one that does; `FIONREAD`: `argument`
///   is an u32 that gets the bytes of the next datagram, 0 if none - on a
///   stream socket, every byte there is to read.
/// - `argument` - as the request says.
///
/// RESULT:
/// 0, or -1 with Errno(): `EBADF`, `EINVAL` (a request there is not).
///
/// BEHAVIOR:
/// A socket that does not wait answers `EWOULDBLOCK` where it would have
/// waited.
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
/// FIONREAD counts the next datagram, which is what one RecvFrom takes.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetSockOpt`, `RecvFrom`, `WaitSelect`
///
/// EXAMPLES:
/// ```zig
/// var never: i32 = 1;
/// _ = sb.IoctlSocket(socket, bsd.FIONBIO, &never);
/// ```
pub fn IoctlSocket(sb: *SocketBase, descriptor: i32, request: u32, argument: *anyopaque) i32 {
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    const socket = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "IoctlSocket");
    switch (request) {
        bsd.FIONBIO => {
            if (@as(*align(1) const i32, @ptrCast(argument)).* != 0) {
                socket.flags |= _socket.nonblocking;
            } else {
                socket.flags &= ~_socket.nonblocking;
            }
        },
        bsd.FIONREAD => {
            var next: u32 = 0;
            if (socket.socket_type == bsd.SOCK_STREAM) {
                next = _tcp.of(socket).receive.count;
            } else if (socket.receive.first()) |node| next = @as(*Frame, @fieldParentPtr("node", node)).length;
            @as(*align(1) u32, @ptrCast(argument)).* = next;
        },
        else => return _socket.fail(sb, bsd.EINVAL, "IoctlSocket"),
    }
    return 0;
}
