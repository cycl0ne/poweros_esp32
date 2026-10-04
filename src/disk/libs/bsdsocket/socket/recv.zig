// SPDX-License-Identifier: MIT
//! Recv: the next datagram in.

const sdk = @import("sdk");
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;

/// The next datagram waiting on the socket, into `buffer`.
///
/// SYNOPSIS:
/// ```zig
/// fn Recv(base: *SocketBase, socket: i32, buffer: *anyopaque, length: u32, flags: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `socket` - a datagram socket.
/// - `buffer` - where the data goes.
/// - `length` - its size.
/// - `flags` - as RecvFrom takes them.
///
/// RESULT:
/// The bytes put in `buffer`, or -1 with Errno(), as RecvFrom.
///
/// BEHAVIOR:
/// RecvFrom without the sender's address.
///
/// CONTEXT:
/// - Waits: yes, unless the socket does not wait.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do; the one that opened the base.
///
/// OWNERSHIP:
/// As RecvFrom.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RecvFrom`, `Send`, `Connect`
///
/// EXAMPLES:
/// ```zig
/// var buffer: [512]u8 = undefined;
/// const got = sb.Recv(socket, &buffer, buffer.len, 0);
/// ```
pub fn Recv(sb: *SocketBase, descriptor: i32, buffer: *anyopaque, length: u32, flags: u32) i32 {
    return _base.iface(sb).RecvFrom(descriptor, buffer, length, flags, null, null);
}
