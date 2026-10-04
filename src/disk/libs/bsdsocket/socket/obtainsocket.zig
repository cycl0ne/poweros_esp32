// SPDX-License-Identifier: MIT
//! ObtainSocket: a socket another task handed over, taken.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");

/// The socket handed over under `id`, taken into the opener's table.
///
/// SYNOPSIS:
/// ```zig
/// fn ObtainSocket(base: *SocketBase, id: i32, domain: i32, socket_type: i32, protocol: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -116.
///
/// INPUTS:
/// - `id` - what ReleaseSocket answered.
/// - `domain` - the socket's family, `PF_INET` or `PF_INET6`, as a
///   check; or `PF_UNSPEC` for either, when the taker does not know it.
/// - `socket_type` - the socket's type, as a check.
/// - `protocol` - its protocol, or 0.
///
/// RESULT:
/// Its descriptor in the opener's table, or -1 with Errno(): `EINVAL`
/// (nothing waits under that id, or not of that family or type),
/// `EMFILE`.
///
/// BEHAVIOR:
/// The socket is the opener's from now on: its readiness raises the
/// opener's signal, and closing the library closes it.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The socket becomes the opener's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleaseSocket`
///
/// EXAMPLES:
/// ```zig
/// const socket = sb.ObtainSocket(id, bsd.PF_INET, bsd.SOCK_DGRAM, 0);
/// ```
pub fn ObtainSocket(sb: *SocketBase, id: i32, domain: i32, socket_type: i32, protocol: i32) i32 {
    const stack = sb.stack;
    const held = _lock.take(stack);
    defer _lock.give(stack, held);
    if (domain != bsd.PF_UNSPEC and domain != bsd.PF_INET and domain != bsd.PF_INET6) return _socket.fail(sb, bsd.EINVAL, "ObtainSocket");
    var it = stack.sockets.iterator();
    const socket = while (it.next()) |node| {
        const candidate = _socket.fromNode(node);
        if (candidate.owner == null and candidate.release_id == id) break candidate;
    } else return _socket.fail(sb, bsd.EINVAL, "ObtainSocket");
    if (socket.socket_type != socket_type or (protocol != 0 and socket.protocol != protocol)) return _socket.fail(sb, bsd.EINVAL, "ObtainSocket");
    if (domain != bsd.PF_UNSPEC and socket.family != domain) return _socket.fail(sb, bsd.EINVAL, "ObtainSocket");
    const table = sb.table.?;
    var index: u32 = 0;
    while (index < sb.table_size and table[index] != null) index += 1;
    if (index == sb.table_size) return _socket.fail(sb, bsd.EMFILE, "ObtainSocket");
    table[index] = socket;
    socket.owner = sb;
    socket.descriptor = @intCast(index);
    socket.release_id = 0;
    if (_socket.readable(socket)) _socket.wake(socket, bsd.FD_READ);
    return @intCast(index);
}
