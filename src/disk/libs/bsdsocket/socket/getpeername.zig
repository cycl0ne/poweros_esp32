// SPDX-License-Identifier: MIT
//! GetPeerName: the address of a socket's connected peer.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");

/// The address and port the socket is connected to.
///
/// SYNOPSIS:
/// ```zig
/// fn GetPeerName(base: *SocketBase, socket: i32, address: *sockaddr, address_length: *u32) i32
/// ```
///
/// SINCE: 1.0. LVO -60.
///
/// INPUTS:
/// - `socket` - a descriptor from Socket.
/// - `address` - where the `sockaddr_in` goes.
/// - `address_length` - in, the room at `address`; out,
///   `@sizeOf(sockaddr_in)`.
///
/// RESULT:
/// 0, or -1 with Errno(): `EBADF`, `ENOTCONN` (the socket is not
/// connected).
///
/// BEHAVIOR:
/// As much of the address is written as there is room for.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Forbid: not held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetSockName`, `Connect`
///
/// EXAMPLES:
/// ```zig
/// var peer: bsd.sockaddr_in = .{};
/// var size: u32 = @sizeOf(bsd.sockaddr_in);
/// if (sb.GetPeerName(socket, peer.any(), &size) < 0) return sb.Errno();
/// ```
pub fn GetPeerName(sb: *SocketBase, descriptor: i32, address: *bsd.sockaddr, address_length: *u32) i32 {
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    const socket = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "GetPeerName");
    if (socket.flags & _socket.connected == 0) return _socket.fail(sb, bsd.ENOTCONN, "GetPeerName");
    _socket.addressOut(socket.remote_address, socket.remote_port, address, address_length);
    return 0;
}
