// SPDX-License-Identifier: MIT
//! Bind: the local address and port a socket receives on.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _netif = @import("../netif/_netif.zig");

/// The local address and port a socket takes datagrams on and sends from.
///
/// SYNOPSIS:
/// ```zig
/// fn Bind(base: *SocketBase, socket: i32, address: *const sockaddr, address_length: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `socket` - a descriptor from Socket.
/// - `address` - a `sockaddr_in`: an address of this machine, or
///   `INADDR_ANY` for all of them; a port, or 0 for one nobody has.
/// - `address_length` - its size, `@sizeOf(sockaddr_in)`.
///
/// RESULT:
/// 0, or -1 with Errno(): `EBADF`, `EINVAL` (already bound, or a short
/// address), `EAFNOSUPPORT`, `EADDRNOTAVAIL` (not an address of this
/// machine), `EADDRINUSE` (the port is taken on that address).
///
/// BEHAVIOR:
/// A port is taken when another socket of the same type is bound to it on
/// the same address, or either of them is bound to `INADDR_ANY` - unless
/// both set `SO_REUSEADDR`. Port 0 picks the next free one from 49152 up.
/// A socket bound to one address takes only datagrams sent to it; one
/// bound to `INADDR_ANY` takes those to any of the machine's addresses and
/// its broadcasts.
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
/// GetSockName tells which port 0 picked.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Socket`, `Connect`, `GetSockName`, `SetSockOpt`
///
/// EXAMPLES:
/// ```zig
/// var here: bsd.sockaddr_in = .{ .sin_port = bsd.htons(7) };
/// if (sb.Bind(socket, here.anyConst(), @sizeOf(bsd.sockaddr_in)) < 0) return sb.Errno();
/// ```
pub fn Bind(sb: *SocketBase, descriptor: i32, address: *const bsd.sockaddr, address_length: u32) i32 {
    const stack = sb.stack;
    const held = _lock.take(stack);
    defer _lock.give(stack, held);
    const socket = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "Bind");
    if (socket.flags & _socket.bound != 0) return _socket.fail(sb, bsd.EINVAL, "Bind");
    const wanted = _socket.addressIn(sb, address, address_length) orelse return _socket.fail(sb, sb.errno, "Bind");
    if (wanted.address != bsd.INADDR_ANY and !_netif.isOurs(stack, wanted.address)) return _socket.fail(sb, bsd.EADDRNOTAVAIL, "Bind");
    socket.local_address = wanted.address;
    if (wanted.port == 0) {
        if (!_socket.bindAnyPort(stack, socket)) return _socket.fail(sb, bsd.EADDRNOTAVAIL, "Bind");
        return 0;
    }
    if (_socket.portTaken(stack, socket.socket_type, wanted.address, wanted.port, socket)) |other| {
        const both_reuse = socket.flags & other.flags & _socket.reuse_address != 0;
        if (!both_reuse) {
            socket.local_address = bsd.INADDR_ANY;
            return _socket.fail(sb, bsd.EADDRINUSE, "Bind");
        }
    }
    socket.local_port = wanted.port;
    socket.flags |= _socket.bound;
    return 0;
}
