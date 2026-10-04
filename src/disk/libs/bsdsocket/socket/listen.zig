// SPDX-License-Identifier: MIT
//! Listen: a stream socket made to take connections.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");
const tcp_user = @import("../tcp/user.zig");

/// A stream socket made a listener: connections to its port are taken
/// and wait for Accept.
///
/// SYNOPSIS:
/// ```zig
/// fn Listen(base: *SocketBase, socket: i32, backlog: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -120.
///
/// INPUTS:
/// - `socket` - a stream socket, not connected.
/// - `backlog` - how many connections may wait for Accept, from 1 to
///   `SOMAXCONN` (8); more is taken as 8.
///
/// RESULT:
/// 0, or -1 with Errno(): `EBADF`, `EOPNOTSUPP` (not a stream socket),
/// `EINVAL` (connecting or connected), `EADDRNOTAVAIL`.
///
/// BEHAVIOR:
/// A socket not bound yet is bound to a port nobody has, which
/// GetSockName tells. A SYN to the port makes a connection at once and
/// answers it; the connection waits, once it stands, until Accept takes
/// it. When `backlog` connections wait already, further SYNs are left
/// unanswered, and their senders try again. Calling Listen again changes
/// the backlog.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// WaitSelect says a listener is ready to read when a connection waits.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Accept`, `Bind`, `Socket`
///
/// EXAMPLES:
/// ```zig
/// var here: bsd.sockaddr_in = .{ .sin_port = bsd.htons(23) };
/// _ = sb.Bind(server, here.anyConst(), @sizeOf(bsd.sockaddr_in));
/// if (sb.Listen(server, 4) < 0) return sb.Errno();
/// ```
pub fn Listen(sb: *SocketBase, descriptor: i32, backlog: i32) i32 {
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    const socket = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "Listen");
    if (socket.socket_type != bsd.SOCK_STREAM) return _socket.fail(sb, bsd.EOPNOTSUPP, "Listen");
    const refused = tcp_user.listen(sb.stack, socket, backlog);
    if (refused != 0) return _socket.fail(sb, refused, "Listen");
    return 0;
}
