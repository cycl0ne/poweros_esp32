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
const _icmp6 = @import("../icmp6/_icmp6.zig");
const tcp_user = @import("../tcp/user.zig");

/// A datagram of `length` bytes sent to `to`, or to the peer the socket is
/// connected to; for a stream socket, `length` bytes written to its
/// connection.
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
/// - `socket` - a datagram socket, a raw ICMP socket, or a connected
///   stream socket.
/// - `message` - the data; for a raw socket, the whole ICMP message.
/// - `length` - its bytes; 0 sends an empty datagram.
/// - `flags` - 0, or `MSG_DONTWAIT`: a stream socket takes what fits
///   now and does not wait for the rest. A datagram is sent or refused at
///   once either way.
/// - `to` - a `sockaddr_in`, or null on a connected socket; null on a
///   stream socket.
/// - `to_length` - its size.
///
/// RESULT:
/// `length` - for a stream socket that does not wait, what fitted in its
/// ring - or -1 with Errno(): `EPIPE` (the stream was shut for writing or
/// has ended), `ENOTCONN` (not connected), `EWOULDBLOCK` (no room, and it
/// does not wait), `EINTR`, `EBADF`, `EDESTADDRREQ` (no address and
/// not connected), `EISCONN` (an address on a connected socket),
/// `EAFNOSUPPORT`, `EINVAL`, `EOPNOTSUPP` (a capture socket), `EMSGSIZE`
/// (more than the interface takes),
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
/// A stream socket copies the bytes into its send ring - waiting for room
/// while the peer's window is shut, unless it does not wait - and sends
/// them as the window and the peer's MSS allow; they may still be on
/// their way when this returns.
///
/// CONTEXT:
/// - Waits: for a stream socket, while its ring is full.
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
    const stack = sb.stack;
    defer _socket.stopTimer(sb);
    var held = _lock.take(stack);
    defer _lock.give(stack, held);
    const socket = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "SendTo");
    if (socket.pending_error != 0) {
        const errno = socket.pending_error;
        socket.pending_error = 0;
        return _socket.fail(sb, errno, "SendTo");
    }
    if (socket.flags & _socket.capture != 0) return _socket.fail(sb, bsd.EOPNOTSUPP, "SendTo");
    const bytes: [*]const u8 = @ptrCast(message);
    if (socket.socket_type == bsd.SOCK_STREAM) {
        if (to != null) return _socket.fail(sb, bsd.EISCONN, "SendTo");
        return sendStream(sb, descriptor, socket, bytes[0..length], flags, &held);
    }
    var destination = socket.remote_address;
    var port: u16 = socket.remote_port;
    var scope: ?*@import("../netif/_netif.zig").Interface = null;
    if (to) |address| {
        if (socket.flags & _socket.connected != 0) return _socket.fail(sb, bsd.EISCONN, "SendTo");
        const peer = _socket.addressIn(sb, socket, address, to_length) orelse return _socket.fail(sb, sb.errno, "SendTo");
        destination = peer.address;
        port = peer.port;
        scope = peer.scope;
    } else if (socket.flags & _socket.connected == 0) {
        return _socket.fail(sb, bsd.EDESTADDRREQ, "SendTo");
    }
    if (length > _udp.data_max) return _socket.fail(sb, bsd.EMSGSIZE, "SendTo");
    const data: [*]const u8 = @ptrCast(message);
    const refused = if (socket.socket_type != bsd.SOCK_RAW)
        _udp.output(stack, socket, destination, port, scope, data[0..length])
    else if (socket.protocol == bsd.IPPROTO_ICMPV6)
        _icmp6.output(stack, socket, destination, scope, data[0..length])
    else
        _icmp.output(stack, socket, destination, data[0..length]);
    if (refused != 0) return _socket.fail(sb, refused, "SendTo");
    return @intCast(length);
}

/// Bytes into a connection's send ring, waiting for room as often as it
/// takes, unless the socket or the call does not wait: then as much as
/// there is room for.
fn sendStream(sb: *SocketBase, descriptor: i32, socket: *_socket.Socket, bytes: []const u8, flags: u32, held: *@import("../lock/_lock.zig").Held) i32 {
    const sys = sb.sys_base;
    const waits = socket.flags & _socket.nonblocking == 0 and flags & bsd.MSG_DONTWAIT == 0;
    var sent: u32 = 0;
    _ = sys.SetSignal(0, sb.ready_mask);
    while (true) {
        const current = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "SendTo");
        if (current != socket) return _socket.fail(sb, bsd.EBADF, "SendTo");
        if (socket.pending_error != 0 and sent == 0) {
            const errno = socket.pending_error;
            socket.pending_error = 0;
            return _socket.fail(sb, errno, "SendTo");
        }
        switch (tcp_user.send(sb.stack, socket, bytes[sent..])) {
            .errno => |errno| return if (sent > 0) @intCast(sent) else _socket.fail(sb, errno, "SendTo"),
            .taken => |taken| sent += taken,
        }
        if (sent == bytes.len) return @intCast(sent);
        if (!waits) return if (sent > 0) @intCast(sent) else _socket.fail(sb, bsd.EWOULDBLOCK, "SendTo");
        if (sb.timer_armed == 0 and !_socket.isZero(socket.send_timeout)) _ = _socket.startTimer(sb, socket.send_timeout);
        var came: u32 = 0;
        switch (_socket.wait(sb, held, 0, &came)) {
            .broken => return if (sent > 0) @intCast(sent) else _socket.fail(sb, bsd.EINTR, "SendTo"),
            .timed_out => return if (sent > 0) @intCast(sent) else _socket.fail(sb, bsd.EWOULDBLOCK, "SendTo"),
            .changed, .signalled => {},
        }
    }
}
