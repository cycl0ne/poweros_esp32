// SPDX-License-Identifier: MIT
//! RecvMsg: the next datagram in, spread over several buffers, with its
//! sender and what the stack knows of it as control messages. RecvFrom
//! and Recv are this with one buffer.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _socket = @import("_socket.zig");
const Socket = _socket.Socket;
const _lock = @import("../lock/_lock.zig");
const tcp_user = @import("../tcp/user.zig");

/// The next datagram waiting on the socket, spread over `message`'s
/// buffers in turn, the address it came from, and control messages about
/// it; for a stream socket, what has come on its connection.
///
/// SYNOPSIS:
/// ```zig
/// fn RecvMsg(base: *SocketBase, socket: i32, message: *msghdr, flags: u32) i32
/// ```
///
/// SINCE: 1.3. LVO -212.
///
/// INPUTS:
/// - `socket` - a descriptor from Socket.
/// - `message` - `msg_iov` and `msg_iovlen`, the buffers; `msg_name` and
///   `msg_namelen`, where the sender's address goes and its room (null
///   and 0 for none); `msg_control` and `msg_controllen`, room for control
///   messages (null and 0 for none).
/// - `flags` - as RecvFrom's: `MSG_PEEK`, `MSG_DONTWAIT`, `MSG_OOB`.
///
/// RESULT:
/// The bytes put in the buffers - 0 at the end of a stream - or -1 with
/// Errno(), as RecvFrom; `EINVAL` as well for buffers whose sizes add up
/// past 2 GiB. `msg_namelen` is the address's size, `msg_controllen` the
/// bytes of control messages written, and `msg_flags` holds `MSG_TRUNC`
/// when a datagram was longer than the buffers and `MSG_CTRUNC` when a
/// control message did not fit.
///
/// BEHAVIOR:
/// A datagram fills the first buffer, then the next, and what is left
/// when they are full is lost. With `IPV6_RECVHOPLIMIT` set on the
/// socket, an IPv6 datagram - UDP, or ICMPv6 on a raw socket - comes with
/// a control message of level `IPPROTO_IPV6` and type `IPV6_HOPLIMIT`:
/// the hop limit it arrived with, an i32. Waiting is as RecvFrom's.
///
/// CONTEXT:
/// - Waits: yes, unless the socket does not wait.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do; it must be the one that opened the base,
///   whose signals the wait is on.
///
/// OWNERSHIP:
/// The datagram is copied into the buffers and its frame given back;
/// `message` and what it points to stay the caller's.
///
/// NOTES:
/// `sdk.bsdsocket.cmsgFirst`, `cmsgNext` and `cmsgData` walk the control
/// messages; `cmsgSpace` says how much room one takes.
///
/// BUGS:
/// A stream socket read with `MSG_PEEK` fills only the first buffer.
///
/// SEE ALSO:
/// `RecvFrom`, `SetSockOpt`, `WaitSelect`
///
/// EXAMPLES:
/// ```zig
/// var data: [512]u8 = undefined;
/// var vector = [_]bsd.iovec{.{ .iov_base = &data, .iov_len = data.len }};
/// var control: [64]u8 align(4) = undefined;
/// var message: bsd.msghdr = .{ .msg_iov = &vector, .msg_iovlen = 1, .msg_control = &control, .msg_controllen = control.len };
/// const got = sb.RecvMsg(socket, &message, 0);
/// var next = bsd.cmsgFirst(&message);
/// while (next) |cmsg| : (next = bsd.cmsgNext(&message, cmsg)) {
///     if (cmsg.cmsg_level == bsd.IPPROTO_IPV6 and cmsg.cmsg_type == bsd.IPV6_HOPLIMIT) {
///         const hops = @as(*align(1) const i32, @ptrCast(bsd.cmsgData(cmsg))).*;
///         _ = hops;
///     }
/// }
/// ```
pub fn RecvMsg(sb: *SocketBase, descriptor: i32, message: *bsd.msghdr, flags: u32) i32 {
    const sys = sb.sys_base;
    const stack = sb.stack;
    const vectors: []const bsd.iovec = if (message.msg_iov) |many| many[0..message.msg_iovlen] else &.{};
    var room: u64 = 0;
    for (vectors) |vector| room += vector.iov_len;
    if (room > 0x7FFF_FFFF) return _socket.fail(sb, bsd.EINVAL, "RecvMsg");
    const from: ?*bsd.sockaddr = @ptrCast(@alignCast(message.msg_name));
    const control_room = message.msg_controllen;
    message.msg_flags = 0;
    message.msg_controllen = 0;
    // The timer is stopped after the lock is let go: stopping it waits
    // for its request to come back.
    defer _socket.stopTimer(sb);
    var held = _lock.take(stack);
    defer _lock.give(stack, held);
    // A readiness signal from before this call says nothing about it.
    _ = sys.SetSignal(0, sb.ready_mask);
    while (true) {
        const socket = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "RecvMsg");
        if (flags & bsd.MSG_OOB != 0) {
            if (socket.socket_type != bsd.SOCK_STREAM) return _socket.fail(sb, bsd.EOPNOTSUPP, "RecvMsg");
            switch (tcp_user.receiveUrgent(socket, flags & bsd.MSG_PEEK != 0)) {
                .errno => |errno| return _socket.fail(sb, errno, "RecvMsg"),
                .byte => |byte| {
                    const first = firstBuffer(vectors) orelse return 0;
                    first[0] = byte;
                    return 1;
                },
            }
        }
        if (socket.pending_error != 0) {
            const errno = socket.pending_error;
            socket.pending_error = 0;
            return _socket.fail(sb, errno, "RecvMsg");
        }
        if (socket.socket_type == bsd.SOCK_STREAM) {
            if (tcp_user.unconnected(socket)) return _socket.fail(sb, bsd.ENOTCONN, "RecvMsg");
            if (receiveStream(stack, socket, vectors, flags & bsd.MSG_PEEK != 0)) |taken| {
                if (from) |address| _socket.addressOut(stack, socket, socket.remote_address, socket.remote_port, socket.scope, address, &message.msg_namelen);
                return @intCast(taken);
            }
        } else if (socket.receive.first()) |node| {
            const frame: *Frame = @fieldParentPtr("node", node);
            const data = frame.bytes();
            var taken: usize = 0;
            for (vectors) |vector| {
                const into: [*]u8 = @ptrCast(vector.iov_base orelse continue);
                const part = @min(vector.iov_len, data.len - taken);
                @memcpy(into[0..part], data[taken..][0..part]);
                taken += part;
                if (taken == data.len) break;
            }
            if (taken < data.len) message.msg_flags |= bsd.MSG_TRUNC;
            if (from) |address| _socket.addressOut(stack, socket, frame.from_address, frame.from_port, frame.from_interface, address, &message.msg_namelen);
            if (socket.receive_hop_limit != 0 and !frame.from_address.isV4()) {
                control(message, control_room, bsd.IPPROTO_IPV6, bsd.IPV6_HOPLIMIT, frame.hop_limit);
            }
            if (flags & bsd.MSG_PEEK == 0) {
                sys.Remove(node);
                socket.receive_bytes -= frame.cost();
                stack.frames.give(sys, frame);
            }
            return @intCast(taken);
        }
        if (socket.flags & _socket.nonblocking != 0 or flags & bsd.MSG_DONTWAIT != 0) {
            return _socket.fail(sb, bsd.EWOULDBLOCK, "RecvMsg");
        }
        if (sb.timer_armed == 0 and !_socket.isZero(socket.receive_timeout)) {
            _ = _socket.startTimer(sb, socket.receive_timeout);
        }
        var came: u32 = 0;
        switch (_socket.wait(sb, &held, 0, &came)) {
            .broken => return _socket.fail(sb, bsd.EINTR, "RecvMsg"),
            .timed_out => return _socket.fail(sb, bsd.EWOULDBLOCK, "RecvMsg"),
            .changed, .signalled => {},
        }
    }
}

/// The first buffer with room, if there is one.
fn firstBuffer(vectors: []const bsd.iovec) ?[*]u8 {
    for (vectors) |vector| {
        if (vector.iov_len != 0) return @ptrCast(vector.iov_base orelse continue);
    }
    return null;
}

/// What a stream has for `vectors`, each filled before the next: the
/// bytes, 0 at its end, or null while nothing has come. A peek fills only
/// the first buffer.
fn receiveStream(stack: *_base.StackBase, socket: *Socket, vectors: []const bsd.iovec, peek: bool) ?usize {
    var total: ?usize = null;
    for (vectors) |vector| {
        if (vector.iov_len == 0) continue;
        const into: [*]u8 = @ptrCast(vector.iov_base orelse continue);
        const taken = tcp_user.receive(stack, socket, into[0..vector.iov_len], peek) orelse break;
        total = (total orelse 0) + taken;
        if (peek or taken < vector.iov_len) break;
    } else if (total == null) {
        // No buffer with room: what an empty read says - wait, or the end.
        var none: [0]u8 = .{};
        return if (tcp_user.receive(stack, socket, &none, peek)) |taken| taken else null;
    }
    return total;
}

/// An i32 control message of `level` and `kind` added to `message`'s
/// control room of `room` bytes, or MSG_CTRUNC when it does not fit.
fn control(message: *bsd.msghdr, room: u32, level: i32, kind: i32, value: i32) void {
    const at = message.msg_controllen;
    const space = bsd.cmsgSpace(@sizeOf(i32));
    const memory: [*]u8 = @ptrCast(message.msg_control orelse {
        message.msg_flags |= bsd.MSG_CTRUNC;
        return;
    });
    if (at + bsd.cmsgLen(@sizeOf(i32)) > room) {
        message.msg_flags |= bsd.MSG_CTRUNC;
        return;
    }
    const header: *align(1) bsd.cmsghdr = @ptrCast(memory + at);
    header.* = .{ .cmsg_len = bsd.cmsgLen(@sizeOf(i32)), .cmsg_level = level, .cmsg_type = kind };
    @as(*align(1) i32, @ptrCast(memory + at + bsd.cmsgAlign(@sizeOf(bsd.cmsghdr)))).* = value;
    message.msg_controllen = @min(at + space, room);
}
