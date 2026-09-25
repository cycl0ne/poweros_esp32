// SPDX-License-Identifier: MIT
//! CloseSocket: a socket closed.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");

/// The socket closed and its descriptor free for the next Socket.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseSocket(base: *SocketBase, socket: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -68.
///
/// INPUTS:
/// - `socket` - a descriptor from Socket.
///
/// RESULT:
/// 0, or -1 with Errno() `EBADF`.
///
/// BEHAVIOR:
/// The datagrams still waiting on it are dropped, and its port is free
/// again. A call of another task waiting on the socket finds it gone and
/// answers `EBADF`.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Forbid: not held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The socket is gone; the descriptor may name a new one after the next
/// Socket.
///
/// NOTES:
/// Closing the library closes every socket still open.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Socket`
///
/// EXAMPLES:
/// ```zig
/// defer _ = sb.CloseSocket(socket);
/// ```
pub fn CloseSocket(sb: *SocketBase, descriptor: i32) i32 {
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    const socket = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "CloseSocket");
    _socket.destroy(sb, socket);
    return 0;
}
