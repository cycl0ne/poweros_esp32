// SPDX-License-Identifier: MIT
//! RecvMMsg: the datagrams waiting on a socket, several in one call, each
//! read as RecvMsg reads one - under one take of the stack's lock, which
//! is what a reader of many small datagrams waits for most.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");
const recvmsg = @import("recvmsg.zig");

/// Up to `count` datagrams, each into its own message as RecvMsg reads
/// one: it waits for the first, as RecvMsg does, then takes only those
/// already there.
///
/// SYNOPSIS:
/// ```zig
/// fn RecvMMsg(base: *SocketBase, socket: i32, messages: [*]mmsghdr, count: u32, flags: u32) i32
/// ```
///
/// SINCE: 1.20. LVO -224.
///
/// INPUTS:
/// - `socket` - a descriptor from Socket.
/// - `messages` - `count` mmsghdrs: each one's `msg_hdr` as RecvMsg's
///   `message` - its buffers, room for the sender and for control
///   messages.
/// - `count` - how many there are room for.
/// - `flags` - 0, or `MSG_DONTWAIT`: not even the first is waited for.
///
/// RESULT:
/// How many messages were filled - 0 when `count` is 0 - or -1 with
/// Errno() when the first could not be: as RecvMsg's, and `EINVAL` for
/// `MSG_PEEK` or `MSG_OOB`. Each filled one has its bytes in `msg_len`
/// and its `msg_hdr` as RecvMsg leaves it.
///
/// BEHAVIOR:
/// Past the first it stops at the first message nothing is waiting for,
/// and at an error, which the next call tells. A stream socket fills each
/// message with what has come, as RecvMsg does, and stops when nothing
/// more has; its end is a message of 0 bytes, the first of a call.
///
/// CONTEXT:
/// - Waits: for the first datagram, unless the socket does not wait.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do; it must be the one that opened the base,
///   whose signals the wait is on.
///
/// OWNERSHIP:
/// Each datagram is copied into its message's buffers and its frame given
/// back; `messages` and what they point to stay the caller's.
///
/// NOTES:
/// Linux's recvmmsg, without its timeout: SO_RCVTIMEO bounds the wait
/// for the first, as it does RecvMsg's.
///
/// SEE ALSO:
/// `RecvMsg`, `WaitSelect`
///
/// EXAMPLES:
/// ```zig
/// var data: [8][2048]u8 = undefined;
/// var vectors: [8]bsd.iovec = undefined;
/// var messages: [8]bsd.mmsghdr = undefined;
/// for (&data, &vectors, &messages) |*each, *vector, *message| {
///     vector.* = .{ .iov_base = each, .iov_len = each.len };
///     message.* = .{ .msg_hdr = .{ .msg_iov = @ptrCast(vector), .msg_iovlen = 1 } };
/// }
/// const got = sb.RecvMMsg(socket, &messages, messages.len, 0);
/// for (messages[0..@intCast(@max(got, 0))]) |message| {
///     _ = message.msg_len; // the bytes in its buffer
/// }
/// ```
pub fn RecvMMsg(sb: *SocketBase, descriptor: i32, messages: [*]bsd.mmsghdr, count: u32, flags: u32) i32 {
    if (flags & (bsd.MSG_PEEK | bsd.MSG_OOB) != 0) return _socket.fail(sb, bsd.EINVAL, "RecvMMsg");
    if (count == 0) return 0;
    // The timer is stopped after the lock is let go: stopping it waits
    // for its request to come back.
    defer _socket.stopTimer(sb);
    var held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    // A readiness signal from before this call says nothing about it.
    _ = sb.sys_base.SetSignal(0, sb.ready_mask);
    const first = recvmsg.receive(sb, &held, descriptor, &messages[0].msg_hdr, flags, "RecvMMsg");
    if (first < 0) return -1;
    messages[0].msg_len = @intCast(first);
    var filled: u32 = 1;
    while (filled < count) : (filled += 1) {
        // What is waiting, and no error: an error stays for the next call.
        const socket = _socket.lookup(sb, descriptor) orelse break;
        if (socket.pending_error != 0 or !_socket.readable(socket)) break;
        const taken = recvmsg.receive(sb, &held, descriptor, &messages[filled].msg_hdr, flags | bsd.MSG_DONTWAIT, "RecvMMsg");
        // A stream's end, too, is the next call's.
        if (taken < 0 or (taken == 0 and socket.socket_type == bsd.SOCK_STREAM)) break;
        messages[filled].msg_len = @intCast(taken);
    }
    return @intCast(filled);
}
