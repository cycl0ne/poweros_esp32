// SPDX-License-Identifier: MIT
//! Connect: the one peer a datagram socket speaks with.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _tcp = @import("../tcp/_tcp.zig");
const tcp_user = @import("../tcp/user.zig");

/// A connection opened to the peer, for a stream socket; for a datagram
/// socket, the peer it sends to by default and the only one it takes
/// datagrams from.
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
/// `EADDRNOTAVAIL` (no port of its own could be had, or an address that
/// is none or for many); for a stream socket also `EINPROGRESS` (it does
/// not wait, and the connection is on its way), `EALREADY`, `EISCONN`,
/// `ENETUNREACH`, `ECONNREFUSED` (the peer reset it), `ETIMEDOUT`,
/// `EINTR`.
///
/// BEHAVIOR:
/// A stream socket sends its SYN, bound first to a port of its own and
/// to the address of the interface the route picks, and waits until the
/// connection stands or is refused, or `SO_SNDTIMEO` passes. One that does
/// not wait answers `EINPROGRESS` at once; WaitSelect then says it is
/// writable when the connection stands, and `SO_ERROR` why it failed if
/// it did.
///
/// A datagram socket sends nothing: it only remembers the peer. From then
/// on Send needs no address, SendTo refuses one (`EISCONN`), and
/// datagrams from anyone else are left to other sockets or dropped. A
/// socket not yet bound is bound to a port of its own. Connecting again
/// replaces the peer.
///
/// CONTEXT:
/// - Waits: for a stream socket, yes, unless it does not wait.
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
    defer _socket.stopTimer(sb);
    var held = _lock.take(stack);
    defer _lock.give(stack, held);
    const socket = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "Connect");
    if (socket.socket_type == bsd.SOCK_STREAM) {
        const peer = _socket.addressIn(sb, address, address_length) orelse return _socket.fail(sb, sb.errno, "Connect");
        const refused = tcp_user.connect(stack, socket, peer.address, peer.port);
        if (refused != 0) return _socket.fail(sb, refused, "Connect");
        if (socket.flags & _socket.nonblocking != 0) return _socket.fail(sb, bsd.EINPROGRESS, "Connect");
        _ = sb.sys_base.SetSignal(0, sb.ready_mask);
        while (true) {
            const connecting = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "Connect");
            if (connecting != socket) return _socket.fail(sb, bsd.EBADF, "Connect");
            if (socket.pending_error != 0) {
                const errno = socket.pending_error;
                socket.pending_error = 0;
                return _socket.fail(sb, errno, "Connect");
            }
            switch (_tcp.of(socket).state) {
                .syn_sent, .syn_received => {},
                .closed => return _socket.fail(sb, bsd.ECONNREFUSED, "Connect"),
                else => return 0,
            }
            if (sb.timer_armed == 0 and !_socket.isZero(socket.send_timeout)) _ = _socket.startTimer(sb, socket.send_timeout);
            var came: u32 = 0;
            switch (_socket.wait(sb, &held, 0, &came)) {
                .broken => return _socket.fail(sb, bsd.EINTR, "Connect"),
                .timed_out => return _socket.fail(sb, bsd.ETIMEDOUT, "Connect"),
                .changed, .signalled => {},
            }
        }
    }
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
