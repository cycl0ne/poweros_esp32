// SPDX-License-Identifier: MIT
//! SendTo: a datagram out.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _udp = @import("../udp/_udp.zig");
const _icmp = @import("../icmp/_icmp.zig");

/// A datagram of `length` bytes sent to `to`, or to the peer the socket is
/// connected to.
///
/// SYNOPSIS:
/// ```zig
/// fn SendTo(base: *SocketBase, socket: i32, message: *const anyopaque, length: u32, flags: u32,
///     to: ?*const sockaddr, to_length: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `socket` - a datagram socket, or a raw ICMP socket.
/// - `message` - the data; for a raw socket, the whole ICMP message.
/// - `length` - its bytes; 0 sends an empty datagram.
/// - `flags` - 0; `MSG_DONTWAIT` is taken and changes nothing, since a
///   datagram is sent or refused at once.
/// - `to` - a `sockaddr_in`, or null on a connected socket.
/// - `to_length` - its size.
///
/// RESULT:
/// `length`, or -1 with Errno(): `EBADF`, `EDESTADDRREQ` (no address and
/// not connected), `EISCONN` (an address on a connected socket),
/// `EAFNOSUPPORT`, `EINVAL`, `EMSGSIZE` (more than the interface takes),
/// `ENETUNREACH` (no route), `EACCES` (a broadcast without
/// `SO_BROADCAST`), `ENOBUFS` (no frame free), or an error the network
/// reported for an earlier datagram of this socket.
///
/// BEHAVIOR:
/// The datagram is copied into a frame, given its UDP and IPv4 headers,
/// and handed to the interface the route for its address picks, all
/// before the call returns: a datagram to the machine itself is already
/// in its receiver's queue by then. A socket that is not bound is bound
/// to a port of its own first. Nothing is fragmented: a datagram larger
/// than the interface's MTU less 28 bytes of headers is refused.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Forbid: not held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `message` is copied; it is the caller's again when this returns.
///
/// NOTES:
/// "Sent" means handed to the interface. UDP has no acknowledgement, and
/// a datagram may still be lost on the way.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Send`, `RecvFrom`, `Connect`, `SetSockOpt`
///
/// EXAMPLES:
/// ```zig
/// var to: bsd.sockaddr_in = .{ .sin_port = bsd.htons(7), .sin_addr = .{ .s_addr = sb.Inet_Addr("127.0.0.1") } };
/// const text = "hello";
/// _ = sb.SendTo(socket, text, text.len, 0, to.anyConst(), @sizeOf(bsd.sockaddr_in));
/// ```
pub fn SendTo(sb: *SocketBase, descriptor: i32, message: *const anyopaque, length: u32, flags: u32, to: ?*const bsd.sockaddr, to_length: u32) i32 {
    _ = flags;
    const stack = sb.stack;
    const held = _lock.take(stack);
    defer _lock.give(stack, held);
    const socket = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "SendTo");
    if (socket.pending_error != 0) {
        const errno = socket.pending_error;
        socket.pending_error = 0;
        return _socket.fail(sb, errno, "SendTo");
    }
    var destination: u32 = socket.remote_address;
    var port: u16 = socket.remote_port;
    if (to) |address| {
        if (socket.flags & _socket.connected != 0) return _socket.fail(sb, bsd.EISCONN, "SendTo");
        const peer = _socket.addressIn(sb, address, to_length) orelse return _socket.fail(sb, sb.errno, "SendTo");
        destination = peer.address;
        port = peer.port;
    } else if (socket.flags & _socket.connected == 0) {
        return _socket.fail(sb, bsd.EDESTADDRREQ, "SendTo");
    }
    if (length > _udp.data_max) return _socket.fail(sb, bsd.EMSGSIZE, "SendTo");
    const data: [*]const u8 = @ptrCast(message);
    const refused = if (socket.socket_type == bsd.SOCK_RAW)
        _icmp.output(stack, socket, destination, data[0..length])
    else
        _udp.output(stack, socket, destination, port, data[0..length]);
    if (refused != 0) return _socket.fail(sb, refused, "SendTo");
    return @intCast(length);
}
