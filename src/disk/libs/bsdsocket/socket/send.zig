// SPDX-License-Identifier: MIT
//! Send: a datagram to the connected peer.

const sdk = @import("sdk");
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;

/// A datagram of `length` bytes to the peer the socket is connected to.
///
/// SYNOPSIS:
/// ```zig
/// fn Send(base: *SocketBase, socket: i32, message: *const anyopaque, length: u32, flags: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `socket` - a connected datagram socket.
/// - `message` - the data.
/// - `length` - its bytes.
/// - `flags` - as SendTo takes them.
///
/// RESULT:
/// `length`, or -1 with Errno(): as SendTo, and `EDESTADDRREQ` when the
/// socket is not connected.
///
/// BEHAVIOR:
/// SendTo without an address.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `message` is copied.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SendTo`, `Connect`, `Recv`
///
/// EXAMPLES:
/// ```zig
/// _ = sb.Send(socket, "ping", 4, 0);
/// ```
pub fn Send(sb: *SocketBase, descriptor: i32, message: *const anyopaque, length: u32, flags: u32) i32 {
    return _base.iface(sb).SendTo(descriptor, message, length, flags, null, 0);
}
