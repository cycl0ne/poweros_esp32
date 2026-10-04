// SPDX-License-Identifier: MIT
//! Bind: the local address and port a socket receives on.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _netif = @import("../netif/_netif.zig");
const _ip6 = @import("../ip6/_ip6.zig");

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
/// machine), `EADDRINUSE` (the port is taken on that address),
/// `EOPNOTSUPP` (a capture socket).
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
/// - Locks: none needed.
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
    if (socket.flags & _socket.capture != 0) return _socket.fail(sb, bsd.EOPNOTSUPP, "Bind");
    if (socket.flags & _socket.bound != 0) return _socket.fail(sb, bsd.EINVAL, "Bind");
    const wanted = _socket.addressIn(sb, socket, address, address_length) orelse return _socket.fail(sb, sb.errno, "Bind");
    if (!wanted.address.isUnspecified() and !isOurs(stack, wanted.address)) return _socket.fail(sb, bsd.EADDRNOTAVAIL, "Bind");
    socket.local_address = wanted.address;
    if (wanted.address.isLinkLocal()) socket.scope = wanted.scope orelse _ip6.owner(stack, wanted.address);
    if (wanted.port == 0) {
        if (!_socket.bindAnyPort(stack, socket)) return _socket.fail(sb, bsd.EADDRNOTAVAIL, "Bind");
        return 0;
    }
    if (_socket.portTaken(stack, socket, wanted.address, wanted.port)) |other| {
        const both_reuse = socket.flags & other.flags & _socket.reuse_address != 0;
        if (!both_reuse) {
            socket.local_address = .{};
            return _socket.fail(sb, bsd.EADDRINUSE, "Bind");
        }
    }
    socket.local_port = wanted.port;
    socket.flags |= _socket.bound;
    return 0;
}

/// Whether a socket may be bound to `address`: one of this machine's.
fn isOurs(stack: *@import("../bsdsocket_base.zig").StackBase, address: @import("../ip6/address.zig").Address) bool {
    if (address.isV4()) return _netif.isOurs(stack, address.v4());
    return address.eql(@import("../ip6/address.zig").Address.loopback) or _ip6.owner(stack, address) != null;
}
