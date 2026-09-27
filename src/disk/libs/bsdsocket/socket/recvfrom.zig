// SPDX-License-Identifier: MIT
//! RecvFrom: the next datagram in, and who sent it.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");
const tcp_user = @import("../tcp/user.zig");

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
///   `MSG_DONTWAIT` does not wait for this one call.
/// - `from` - where the sender's `sockaddr_in` goes, or null.
/// - `from_length` - in, the room at `from`; out, the address's size. Null
///   when `from` is.
///
/// RESULT:
/// The bytes put in `buffer` - 0 at the end of a stream, once the peer
/// has closed and everything before it is read - or -1 with Errno(): `EBADF`, `EWOULDBLOCK`
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
/// - Forbid: must not be held.
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
/// `Recv`, `SendTo`, `WaitSelect`, `IoctlSocket`
///
/// EXAMPLES:
/// ```zig
/// var buffer: [512]u8 = undefined;
/// var from: bsd.sockaddr_in = .{};
/// var from_length: u32 = @sizeOf(bsd.sockaddr_in);
/// const got = sb.RecvFrom(socket, &buffer, buffer.len, 0, from.any(), &from_length);
/// ```
pub fn RecvFrom(sb: *SocketBase, descriptor: i32, buffer: *anyopaque, length: u32, flags: u32, from: ?*bsd.sockaddr, from_length: ?*u32) i32 {
    const sys = sb.sys_base;
    const stack = sb.stack;
    // The timer is stopped after the lock is let go: stopping it waits
    // for its request to come back.
    defer _socket.stopTimer(sb);
    var held = _lock.take(stack);
    defer _lock.give(stack, held);
    // A readiness signal from before this call says nothing about it.
    _ = sys.SetSignal(0, sb.ready_mask);
    while (true) {
        const socket = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "RecvFrom");
        if (socket.pending_error != 0) {
            const errno = socket.pending_error;
            socket.pending_error = 0;
            return _socket.fail(sb, errno, "RecvFrom");
        }
        if (socket.socket_type == bsd.SOCK_STREAM) {
            const into: [*]u8 = @ptrCast(buffer);
            if (tcp_user.receive(stack, socket, into[0..length], flags & bsd.MSG_PEEK != 0)) |taken| {
                if (from) |address| _socket.addressOut(stack, socket, socket.remote_address, socket.remote_port, socket.scope, address, from_length.?);
                return @intCast(taken);
            }
        } else if (socket.receive.first()) |node| {
            const frame: *Frame = @fieldParentPtr("node", node);
            const data = frame.bytes();
            const taken: u32 = @min(length, @as(u32, @intCast(data.len)));
            const into: [*]u8 = @ptrCast(buffer);
            @memcpy(into[0..taken], data[0..taken]);
            if (from) |address| _socket.addressOut(stack, socket, frame.from_address, frame.from_port, frame.from_interface, address, from_length.?);
            if (flags & bsd.MSG_PEEK == 0) {
                sys.Remove(node);
                socket.receive_bytes -= @intCast(data.len);
                stack.frames.give(sys, frame);
            }
            return @intCast(taken);
        }
        if (socket.flags & _socket.nonblocking != 0 or flags & bsd.MSG_DONTWAIT != 0) {
            return _socket.fail(sb, bsd.EWOULDBLOCK, "RecvFrom");
        }
        if (sb.timer_armed == 0 and !_socket.isZero(socket.receive_timeout)) {
            _ = _socket.startTimer(sb, socket.receive_timeout);
        }
        var came: u32 = 0;
        switch (_socket.wait(sb, &held, 0, &came)) {
            .broken => return _socket.fail(sb, bsd.EINTR, "RecvFrom"),
            .timed_out => return _socket.fail(sb, bsd.EWOULDBLOCK, "RecvFrom"),
            .changed, .signalled => {},
        }
    }
}
