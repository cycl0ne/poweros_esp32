// SPDX-License-Identifier: MIT
//! GetSockName: a socket's local address.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");

/// The address and port the socket is bound to.
///
/// SYNOPSIS:
/// ```zig
/// fn GetSockName(base: *SocketBase, socket: i32, address: *sockaddr, address_length: *u32) i32
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// - `socket` - a descriptor from Socket.
/// - `address` - where the `sockaddr_in` goes.
/// - `address_length` - in, the room at `address`; out,
///   `@sizeOf(sockaddr_in)`.
///
/// RESULT:
/// 0, or -1 with Errno() `EBADF`.
///
/// BEHAVIOR:
/// A socket not bound yet answers `INADDR_ANY` and port 0. As much of the
/// address is written as there is room for.
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
/// How to learn the port Bind picked for port 0.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetPeerName`, `Bind`
///
/// EXAMPLES:
/// ```zig
/// var here: bsd.sockaddr_in = .{};
/// var size: u32 = @sizeOf(bsd.sockaddr_in);
/// _ = sb.GetSockName(socket, here.any(), &size);
/// const port = bsd.ntohs(here.sin_port);
/// ```
pub fn GetSockName(sb: *SocketBase, descriptor: i32, address: *bsd.sockaddr, address_length: *u32) i32 {
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    const socket = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "GetSockName");
    _socket.addressOut(sb.stack, socket, socket.local_address, socket.local_port, socket.scope, address, address_length);
    return 0;
}
