// SPDX-License-Identifier: MIT
//! Accept: a connection taken from a listener.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");
const tcp_user = @import("../tcp/user.zig");

/// The next connection a listener took, as a socket of the caller's own,
/// and the address it came from.
///
/// SYNOPSIS:
/// ```zig
/// fn Accept(base: *SocketBase, socket: i32, address: ?*sockaddr, address_length: ?*u32) i32
/// ```
///
/// SINCE: 1.0. LVO -124.
///
/// INPUTS:
/// - `socket` - a listener (Listen).
/// - `address` - where the peer's `sockaddr_in` goes, or null.
/// - `address_length` - in, the room at `address`; out, the address's
///   size. Null when `address` is.
///
/// RESULT:
/// The new connection's descriptor, or -1 with Errno(): `EBADF`,
/// `EINVAL` (not a listener), `EMFILE` (the table is full; the
/// connection keeps waiting), `EWOULDBLOCK` (none waits, and the socket
/// does not wait), `EINTR`.
///
/// BEHAVIOR:
/// With no connection waiting, the call waits for one, for a break
/// signal, or for `SO_RCVTIMEO`. The new socket is connected, bound to
/// the listener's port, and waits in its calls as the listener does; the
/// listener goes on listening.
///
/// CONTEXT:
/// - Waits: yes, unless the listener does not wait.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do; the one that opened the base.
///
/// OWNERSHIP:
/// The connection is the caller's, to CloseSocket.
///
/// NOTES:
/// To serve it on another task, hand it over with ReleaseSocket.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Listen`, `ReleaseSocket`, `WaitSelect`
///
/// EXAMPLES:
/// ```zig
/// var peer: bsd.sockaddr_in = .{};
/// var size: u32 = @sizeOf(bsd.sockaddr_in);
/// const connection = sb.Accept(server, peer.any(), &size);
/// ```
pub fn Accept(sb: *SocketBase, descriptor: i32, address: ?*bsd.sockaddr, address_length: ?*u32) i32 {
    const stack = sb.stack;
    defer _socket.stopTimer(sb);
    var held = _lock.take(stack);
    defer _lock.give(stack, held);
    _ = sb.sys_base.SetSignal(0, sb.ready_mask);
    while (true) {
        const listener = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "Accept");
        if (listener.socket_type != bsd.SOCK_STREAM or !isListening(listener)) return _socket.fail(sb, bsd.EINVAL, "Accept");
        if (tcp_user.readable(listener)) {
            const index = freeDescriptor(sb) orelse return _socket.fail(sb, bsd.EMFILE, "Accept");
            const connection = tcp_user.accept(stack, listener).?;
            sb.table.?[index] = connection;
            connection.descriptor = @intCast(index);
            connection.owner = sb;
            if (address) |into| _socket.addressOut(sb.stack, connection, connection.remote_address, connection.remote_port, connection.scope, into, address_length.?);
            return @intCast(index);
        }
        if (listener.flags & _socket.nonblocking != 0) return _socket.fail(sb, bsd.EWOULDBLOCK, "Accept");
        if (sb.timer_armed == 0 and !_socket.isZero(listener.receive_timeout)) _ = _socket.startTimer(sb, listener.receive_timeout);
        var came: u32 = 0;
        switch (_socket.wait(sb, &held, 0, &came)) {
            .broken => return _socket.fail(sb, bsd.EINTR, "Accept"),
            .timed_out => return _socket.fail(sb, bsd.EWOULDBLOCK, "Accept"),
            .changed, .signalled => {},
        }
    }
}

fn isListening(socket: *_socket.Socket) bool {
    return @import("../tcp/_tcp.zig").of(socket).state == .listen;
}

fn freeDescriptor(sb: *SocketBase) ?u32 {
    for (sb.table.?[0..sb.table_size], 0..) |entry, index| {
        if (entry == null) return @intCast(index);
    }
    return null;
}
