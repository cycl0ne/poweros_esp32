// SPDX-License-Identifier: MIT
//! Connect: the one peer a datagram socket speaks with.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");

/// The peer a datagram socket sends to by default, and the only one it
/// takes datagrams from.
///
/// SYNOPSIS:
/// ```zig
/// fn Connect(base: *SocketBase, socket: i32, address: *const sockaddr, address_length: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `socket` - a descriptor from Socket.
/// - `address` - the peer, a `sockaddr_in`; one whose family is
///   `AF_UNSPEC` undoes the connection.
/// - `address_length` - its size.
///
/// RESULT:
/// 0, or -1 with Errno(): `EBADF`, `EINVAL`, `EAFNOSUPPORT`,
/// `EADDRNOTAVAIL` (no port of its own could be had).
///
/// BEHAVIOR:
/// Nothing is sent: a datagram socket only remembers the peer. From then
/// on Send needs no address, SendTo refuses one (`EISCONN`), and
/// datagrams from anyone else are left to other sockets or dropped. A
/// socket not yet bound is bound to a port of its own. Connecting again
/// replaces the peer.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Forbid: not held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `address` is read and not kept.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Send`, `Recv`, `GetPeerName`, `Bind`
///
/// EXAMPLES:
/// ```zig
/// var peer: bsd.sockaddr_in = .{ .sin_port = bsd.htons(7), .sin_addr = .{ .s_addr = sb.Inet_Addr("10.0.2.2") } };
/// if (sb.Connect(socket, peer.anyConst(), @sizeOf(bsd.sockaddr_in)) < 0) return sb.Errno();
/// ```
pub fn Connect(sb: *SocketBase, descriptor: i32, address: *const bsd.sockaddr, address_length: u32) i32 {
    const stack = sb.stack;
    const held = _lock.take(stack);
    defer _lock.give(stack, held);
    const socket = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "Connect");
    if (address_length >= 2 and address.sa_family == bsd.AF_UNSPEC) {
        socket.flags &= ~_socket.connected;
        socket.remote_address = 0;
        socket.remote_port = 0;
        return 0;
    }
    const peer = _socket.addressIn(sb, address, address_length) orelse return _socket.fail(sb, sb.errno, "Connect");
    if (peer.port == 0) return _socket.fail(sb, bsd.EINVAL, "Connect");
    if (socket.flags & _socket.bound == 0) {
        if (!_socket.bindAnyPort(stack, socket)) return _socket.fail(sb, bsd.EADDRNOTAVAIL, "Connect");
    }
    socket.remote_address = peer.address;
    socket.remote_port = peer.port;
    socket.flags |= _socket.connected;
    return 0;
}
