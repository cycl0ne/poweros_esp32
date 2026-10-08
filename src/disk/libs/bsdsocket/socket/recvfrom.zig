// SPDX-License-Identifier: MIT
//! RecvFrom: the next datagram in, and who sent it.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;

/// The next datagram waiting on the socket, into `buffer`, and the address
/// it came from; for a stream socket, what has come on its connection.
///
/// SYNOPSIS:
/// ```zig
/// fn RecvFrom(base: *SocketBase, socket: i32, buffer: *anyopaque, length: u32, flags: u32,
///     from: ?*sockaddr, from_length: ?*u32) i32
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `socket` - a datagram socket.
/// - `buffer` - where the data goes.
/// - `length` - its size.
/// - `flags` - `MSG_PEEK` leaves the datagram to be read again;
///   `MSG_DONTWAIT` does not wait for this one call; `MSG_OOB` reads a
///   stream socket's urgent byte instead, and never waits.
/// - `from` - where the sender's `sockaddr_in` goes, or null.
/// - `from_length` - in, the room at `from`; out, the address's size. Null
///   when `from` is.
///
/// RESULT:
/// The bytes put in `buffer` - 0 at the end of a stream, once the peer
/// has closed and everything before it is read - or -1 with Errno(): `EBADF`, `ENOTCONN` (a stream socket
/// that never connected, or a listener), `EINVAL` (`MSG_OOB` with no urgent byte, or one
/// read already), `EOPNOTSUPP` (`MSG_OOB` on a socket that is no stream
/// socket), `EWOULDBLOCK`
/// (nothing waiting and the socket does not wait, or `SO_RCVTIMEO`
/// passed), `EINTR` (a break signal came), or an error the network
/// reported for the socket.
///
/// BEHAVIOR:
/// A datagram is read whole or not at all: what does not fit in `buffer`
/// is lost. A stream gives as much as there is, up to `length`; reading
/// opens the window again, and the peer is told at once when it had shut
/// or opens by a segment or more. With nothing waiting, the call waits - without holding the
/// stack - until a datagram comes, one of the opener's break signals
/// (SIGBREAKF_CTRL_C unless SocketBaseTagList changed them) comes, or
/// `SO_RCVTIMEO` passes. A break signal is taken.
///
/// CONTEXT:
/// - Waits: yes, unless the socket does not wait.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do; it must be the one that opened the base,
///   whose signals the wait is on.
///
/// OWNERSHIP:
/// The datagram is copied into `buffer` and its frame given back.
///
/// NOTES:
/// FIONREAD tells the size of the next datagram before it is read.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Recv`, `RecvMsg`, `SendTo`, `WaitSelect`, `IoctlSocket`
///
/// EXAMPLES:
/// ```zig
/// var buffer: [512]u8 = undefined;
/// var from: bsd.sockaddr_in = .{};
/// var from_length: u32 = @sizeOf(bsd.sockaddr_in);
/// const got = sb.RecvFrom(socket, &buffer, buffer.len, 0, from.any(), &from_length);
/// ```
pub fn RecvFrom(sb: *SocketBase, descriptor: i32, buffer: *anyopaque, length: u32, flags: u32, from: ?*bsd.sockaddr, from_length: ?*u32) i32 {
    var vector = [_]bsd.iovec{.{ .iov_base = buffer, .iov_len = length }};
    var message: bsd.msghdr = .{ .msg_name = from, .msg_namelen = if (from_length) |room| room.* else 0, .msg_iov = &vector, .msg_iovlen = 1 };
    const got = _base.iface(sb).RecvMsg(descriptor, &message, flags);
    if (from_length) |size| size.* = message.msg_namelen;
    return got;
}
