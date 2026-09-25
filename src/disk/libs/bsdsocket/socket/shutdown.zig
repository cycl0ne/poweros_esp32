// SPDX-License-Identifier: MIT
//! Shutdown: one or both directions of a connection ended.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");
const tcp_user = @import("../tcp/user.zig");

/// No more receiving, no more sending, or neither, on a connection that
/// otherwise stays.
///
/// SYNOPSIS:
/// ```zig
/// fn Shutdown(base: *SocketBase, socket: i32, how: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -128.
///
/// INPUTS:
/// - `socket` - a connected stream socket.
/// - `how` - `SHUT_RD`, `SHUT_WR` or `SHUT_RDWR`.
///
/// RESULT:
/// 0, or -1 with Errno(): `EBADF`, `EINVAL` (another `how`), `ENOTCONN`
/// (not connected), `EOPNOTSUPP` (not a stream socket).
///
/// BEHAVIOR:
/// `SHUT_WR` sends FIN after what is still to be sent: the peer reads to
/// the end of the stream, and can still send. `SHUT_RD` drops what waits
/// to be read, and what comes later is taken and dropped; a receive
/// answers 0. The socket stays open until CloseSocket.
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
/// How a program says "that is all" and still reads the answer.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseSocket`, `SendTo`, `RecvFrom`
///
/// EXAMPLES:
/// ```zig
/// _ = sb.Send(connection, request, request_length, 0);
/// _ = sb.Shutdown(connection, bsd.SHUT_WR);
/// ```
pub fn Shutdown(sb: *SocketBase, descriptor: i32, how: i32) i32 {
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    const socket = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "Shutdown");
    if (how < bsd.SHUT_RD or how > bsd.SHUT_RDWR) return _socket.fail(sb, bsd.EINVAL, "Shutdown");
    if (socket.socket_type != bsd.SOCK_STREAM) return _socket.fail(sb, bsd.EOPNOTSUPP, "Shutdown");
    const refused = tcp_user.shutdown(sb.stack, socket, how);
    if (refused != 0) return _socket.fail(sb, refused, "Shutdown");
    return 0;
}
