// SPDX-License-Identifier: MIT
//! SetSockOpt: one of a socket's options set.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const timer = sdk.devices.timer;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _netif = @import("../netif/_netif.zig");
const _tcp = @import("../tcp/_tcp.zig");

/// The most a socket may buffer: SO_RCVBUF and SO_SNDBUF are held to it.
const buffer_max: u32 = 256 * 1024;

/// One of the socket's options set.
///
/// SYNOPSIS:
/// ```zig
/// fn SetSockOpt(base: *SocketBase, socket: i32, level: i32, option: i32, value: *const anyopaque, value_length: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `socket` - a descriptor from Socket.
/// - `level` - `SOL_SOCKET`, `IPPROTO_TCP` or `IPPROTO_IPV6`.
/// - `option` - `SO_REUSEADDR`, `SO_BROADCAST` (an i32, not 0 for on),
///   `SO_RCVBUF`, `SO_SNDBUF` (an i32 of bytes), `SO_RCVTIMEO`,
///   `SO_SNDTIMEO` (a timeval; zero waits for ever), `SO_EVENTMASK` (an
///   i32 of FD_* events to be told of with the event signal),
///   `SO_KEEPALIVE` (an i32, a stream socket only), `SO_LINGER` (a
///   `linger`), `SO_BINDTODEVICE` (an interface's name, a capture socket
///   only); at level `IPPROTO_TCP`, `TCP_NODELAY` (an i32); at level
///   `IPPROTO_IPV6`, on a `PF_INET6` socket, `IPV6_V6ONLY` (an i32, not 0
///   for IPv6 only; before Bind), `IPV6_UNICAST_HOPS` (an i32, the hop
///   limit its packets go with, -1 for the interface's),
///   `IPV6_JOIN_GROUP`/`IPV6_LEAVE_GROUP` (an `ipv6_mreq`: a group, on an
///   interface by index or on the route's with 0), `IPV6_MULTICAST_IF` (a
///   u32 index, 0 for the route's), `IPV6_MULTICAST_HOPS` (an i32, -1 for
///   1) and `IPV6_MULTICAST_LOOP` (an i32, 0 to keep this machine's own
///   members from getting a copy).
/// - `value` - the option's value.
/// - `value_length` - its size.
///
/// RESULT:
/// 0, or -1 with Errno(): `EBADF`, `ENOPROTOOPT` (another level or an
/// option there is not, or one that can only be read), `EINVAL` (a value
/// of the wrong size, a hop limit out of range, IPV6_V6ONLY once bound, a
/// group that is no group), `ENXIO` (no interface of that index),
/// `EADDRINUSE` (in the group already), `EADDRNOTAVAIL` (not in the group
/// to leave, or no route to it), `ETOOMANYREFS` (the socket is in as many
/// groups as it can be), `ENOBUFS` (so is the interface).
///
/// BEHAVIOR:
/// `SO_RCVBUF` is how many bytes of datagrams wait on the socket before
/// the next is dropped; it is held to between 1 byte and 256 KiB. On a
/// stream socket it and `SO_SNDBUF` are the sizes of its rings, from 1 KiB
/// to 64 KiB, and change only while the ring is empty (`EINVAL` else).
/// `SO_REUSEADDR` must be set before Bind to count. `SO_SNDTIMEO` is kept
/// and changes nothing for a datagram socket, which never waits to send.
/// `SO_EVENTMASK` with `FD_WRITE` tells of it at once, since a datagram
/// socket can always send. `SO_BINDTODEVICE` holds a capture socket to
/// one interface, or with an empty name to every one again; a name there
/// is no interface of is `ENXIO`.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Forbid: not held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `value` is read and not kept.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetSockOpt`, `IoctlSocket`
///
/// EXAMPLES:
/// ```zig
/// const on: i32 = 1;
/// _ = sb.SetSockOpt(socket, bsd.SOL_SOCKET, bsd.SO_BROADCAST, &on, @sizeOf(i32));
/// ```
pub fn SetSockOpt(sb: *SocketBase, descriptor: i32, level: i32, option: i32, value: *const anyopaque, value_length: u32) i32 {
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    const socket = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "SetSockOpt");
    if (level == bsd.IPPROTO_TCP and socket.socket_type == bsd.SOCK_STREAM and option == bsd.TCP_NODELAY) {
        if (value_length < @sizeOf(i32)) return _socket.fail(sb, bsd.EINVAL, "SetSockOpt");
        const tcb = _tcp.of(socket);
        if (@as(*align(1) const i32, @ptrCast(value)).* != 0) tcb.flags |= _tcp.no_delay else tcb.flags &= ~_tcp.no_delay;
        return 0;
    }
    if (level == bsd.IPPROTO_IPV6 and socket.family == bsd.AF_INET6 and (option == bsd.IPV6_JOIN_GROUP or option == bsd.IPV6_LEAVE_GROUP)) {
        if (value_length < @sizeOf(bsd.ipv6_mreq)) return _socket.fail(sb, bsd.EINVAL, "SetSockOpt");
        const request = @as(*align(1) const bsd.ipv6_mreq, @ptrCast(value)).*;
        const refused = membership(sb, socket, option == bsd.IPV6_JOIN_GROUP, request);
        if (refused != 0) return _socket.fail(sb, refused, "SetSockOpt");
        return 0;
    }
    if (level == bsd.IPPROTO_IPV6 and socket.family == bsd.AF_INET6) {
        if (value_length < @sizeOf(i32)) return _socket.fail(sb, bsd.EINVAL, "SetSockOpt");
        const number = @as(*align(1) const i32, @ptrCast(value)).*;
        switch (option) {
            bsd.IPV6_MULTICAST_IF => {
                const index: u32 = @bitCast(number);
                socket.multicast_interface = if (index == 0) null else (_netif.byIndex(sb.stack, index) orelse return _socket.fail(sb, bsd.ENXIO, "SetSockOpt"));
            },
            bsd.IPV6_MULTICAST_HOPS => {
                if (number < -1 or number > 255) return _socket.fail(sb, bsd.EINVAL, "SetSockOpt");
                // 0 is kept as "1", the default; a hop limit of 0 sends
                // to nobody but this machine, which the loop still does.
                socket.multicast_hops = if (number <= 0) 0 else @intCast(number);
            },
            bsd.IPV6_MULTICAST_LOOP => socket.multicast_no_loop = @intFromBool(number == 0),
            bsd.IPV6_V6ONLY => {
                if (socket.flags & _socket.bound != 0) return _socket.fail(sb, bsd.EINVAL, "SetSockOpt");
                socket.v6only = @intFromBool(number != 0);
            },
            bsd.IPV6_UNICAST_HOPS => {
                if (number < -1 or number > 255) return _socket.fail(sb, bsd.EINVAL, "SetSockOpt");
                socket.hop_limit = if (number <= 0) 0 else @intCast(number);
            },
            else => return _socket.fail(sb, bsd.ENOPROTOOPT, "SetSockOpt"),
        }
        return 0;
    }
    if (level != bsd.SOL_SOCKET) return _socket.fail(sb, bsd.ENOPROTOOPT, "SetSockOpt");
    switch (option) {
        bsd.SO_LINGER => {
            if (value_length < @sizeOf(bsd.linger)) return _socket.fail(sb, bsd.EINVAL, "SetSockOpt");
            socket.linger = @as(*align(1) const bsd.linger, @ptrCast(value)).*;
        },
        bsd.SO_KEEPALIVE => {
            if (value_length < @sizeOf(i32)) return _socket.fail(sb, bsd.EINVAL, "SetSockOpt");
            if (socket.socket_type != bsd.SOCK_STREAM) return _socket.fail(sb, bsd.ENOPROTOOPT, "SetSockOpt");
            const tcb = _tcp.of(socket);
            const timers = @import("../tcp/timers.zig");
            const _timer = @import("../timer/_timer.zig");
            if (@as(*align(1) const i32, @ptrCast(value)).* != 0) {
                tcb.flags |= _tcp.keep_alive;
                timers.keepalive(sb.stack, tcb, _timer.clock(sb.stack));
            } else {
                tcb.flags &= ~_tcp.keep_alive;
                if (tcb.state != .time_wait) _timer.cancel(sb.stack, &tcb.timer_long);
            }
        },
        bsd.SO_BINDTODEVICE => {
            if (socket.flags & _socket.capture == 0) return _socket.fail(sb, bsd.ENOPROTOOPT, "SetSockOpt");
            const text: [*]const u8 = @ptrCast(value);
            var name: [bsd.IFNAMSIZ:0]u8 = @splat(0);
            var length: usize = 0;
            while (length < value_length and length < bsd.IFNAMSIZ - 1 and text[length] != 0) : (length += 1) name[length] = text[length];
            socket.flags &= ~_socket.capture_detached;
            if (length == 0) {
                socket.capture_interface = null;
            } else {
                socket.capture_interface = @import("../netif/_netif.zig").named(sb.stack, &name) orelse return _socket.fail(sb, bsd.ENXIO, "SetSockOpt");
            }
        },
        bsd.SO_EVENTMASK => {
            if (value_length < @sizeOf(i32)) return _socket.fail(sb, bsd.EINVAL, "SetSockOpt");
            socket.event_mask = @bitCast(@as(*align(1) const i32, @ptrCast(value)).*);
            socket.events &= socket.event_mask;
            if (_socket.writable(socket)) _socket.wake(socket, bsd.FD_WRITE);
        },
        bsd.SO_REUSEADDR, bsd.SO_BROADCAST, bsd.SO_RCVBUF, bsd.SO_SNDBUF => {
            if (value_length < @sizeOf(i32)) return _socket.fail(sb, bsd.EINVAL, "SetSockOpt");
            const number = @as(*align(1) const i32, @ptrCast(value)).*;
            switch (option) {
                bsd.SO_REUSEADDR => setFlag(socket, _socket.reuse_address, number != 0),
                bsd.SO_BROADCAST => setFlag(socket, _socket.broadcast_allowed, number != 0),
                bsd.SO_RCVBUF, bsd.SO_SNDBUF => {
                    const bytes = bytesOf(number);
                    if (socket.socket_type == bsd.SOCK_STREAM) {
                        // A stream's buffer is its ring, made anew while
                        // it is empty.
                        const tcb = _tcp.of(socket);
                        const ring = if (option == bsd.SO_RCVBUF) &tcb.receive else &tcb.send;
                        if (!_tcp.resize(sb.stack, ring, bytes)) return _socket.fail(sb, bsd.EINVAL, "SetSockOpt");
                    }
                    if (option == bsd.SO_RCVBUF) socket.receive_limit = bytes else socket.send_limit = bytes;
                },
                else => {},
            }
        },
        bsd.SO_RCVTIMEO, bsd.SO_SNDTIMEO => {
            if (value_length < @sizeOf(timer.TimeVal)) return _socket.fail(sb, bsd.EINVAL, "SetSockOpt");
            const time = @as(*align(1) const timer.TimeVal, @ptrCast(value)).*;
            if (option == bsd.SO_RCVTIMEO) socket.receive_timeout = time else socket.send_timeout = time;
        },
        else => return _socket.fail(sb, bsd.ENOPROTOOPT, "SetSockOpt"),
    }
    return 0;
}

fn setFlag(socket: *_socket.Socket, flag: u32, on: bool) void {
    if (on) socket.flags |= flag else socket.flags &= ~flag;
}

fn bytesOf(number: i32) u32 {
    if (number < 1) return 1;
    const bytes: u32 = @intCast(number);
    return @min(bytes, buffer_max);
}

/// A group joined or left, as an ipv6_mreq asks: 0, or the errno.
fn membership(sb: *SocketBase, socket: *_socket.Socket, join: bool, request: bsd.ipv6_mreq) i32 {
    const stack = sb.stack;
    const Address = @import("../ip6/address.zig").Address;
    const group: Address = .{ .bytes = request.ipv6mr_multiaddr.s6_addr };
    if (!group.isMulticast()) return bsd.EINVAL;
    const interface = if (request.ipv6mr_interface != 0)
        (_netif.byIndex(stack, request.ipv6mr_interface) orelse return bsd.ENXIO)
    else
        ((@import("../inet/_inet.zig").route(stack, group, null) orelse return bsd.EADDRNOTAVAIL).interface);
    const _ip6 = @import("../ip6/_ip6.zig");
    if (!join) {
        for (&socket.groups) |*member| {
            if (member.interface == interface and member.group.eql(group)) {
                _ip6.leaveSocketGroup(stack, interface, group);
                member.* = .{};
                return 0;
            }
        }
        return bsd.EADDRNOTAVAIL;
    }
    if (_socket.isMember(socket, group, interface)) return bsd.EADDRINUSE;
    for (&socket.groups) |*member| {
        if (member.interface != null) continue;
        if (!_ip6.joinSocketGroup(stack, interface, group)) return bsd.ENOBUFS;
        member.* = .{ .group = group, .interface = interface };
        return 0;
    }
    return bsd.ETOOMANYREFS;
}
