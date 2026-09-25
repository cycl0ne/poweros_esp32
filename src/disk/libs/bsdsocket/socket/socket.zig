// SPDX-License-Identifier: MIT
//! Socket: a new socket in the opener's descriptor table.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");

/// A new socket, and the descriptor the other calls know it by.
///
/// SYNOPSIS:
/// ```zig
/// fn Socket(base: *SocketBase, domain: i32, socket_type: i32, protocol: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `domain` - `PF_INET`, the only family there is.
/// - `socket_type` - `SOCK_DGRAM`: datagrams, UDP.
/// - `protocol` - 0 or `IPPROTO_UDP`.
///
/// RESULT:
/// The descriptor, from 0 up, or -1 with Errno(): `EAFNOSUPPORT` for
/// another domain, `ESOCKTNOSUPPORT` for another type, `EPROTONOSUPPORT`
/// for another protocol, `EMFILE` when the descriptor table is full,
/// `ENOMEM`.
///
/// BEHAVIOR:
/// The socket takes the lowest free descriptor. It is bound to nothing
/// and connected to nothing; the first datagram it sends binds it to a
/// port of its own, or Bind chooses one first. It waits in its calls
/// unless FIONBIO says otherwise.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Forbid: not held.
/// - Process: a Task will do; it must be the one that opened the base.
///
/// OWNERSHIP:
/// The socket is the opener's until CloseSocket, or until it closes the
/// library, which closes every socket still open.
///
/// NOTES:
/// Stream sockets (TCP) and raw sockets come with the protocols that
/// serve them.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseSocket`, `Bind`, `SendTo`, `RecvFrom`
///
/// EXAMPLES:
/// ```zig
/// const sb: *SocketBase = @ptrCast(sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse return);
/// defer sys.CloseLibrary(sb.lib());
/// const socket = sb.Socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0);
/// if (socket < 0) return sb.Errno();
/// ```
pub fn Socket(sb: *SocketBase, domain: i32, socket_type: i32, protocol: i32) i32 {
    if (domain != bsd.PF_INET) return _socket.fail(sb, bsd.EAFNOSUPPORT, "Socket");
    if (socket_type != bsd.SOCK_DGRAM) return _socket.fail(sb, bsd.ESOCKTNOSUPPORT, "Socket");
    if (protocol != 0 and protocol != bsd.IPPROTO_UDP) return _socket.fail(sb, bsd.EPROTONOSUPPORT, "Socket");
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    const socket = _socket.create(sb, socket_type, bsd.IPPROTO_UDP) orelse return _socket.fail(sb, sb.errno, "Socket");
    return socket.descriptor;
}
