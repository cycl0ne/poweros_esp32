// SPDX-License-Identifier: MIT
//! ICMP (RFC 792): echoes answered, errors told to the socket they
//! concern, and errors sent for packets nothing here takes.
//!
//! **In**: at least the 8-byte header and a right checksum. A copy of
//! every message goes to each raw ICMP socket, IPv4 header and all, which
//! is how a Ping program sees its echoes come back. An echo request to
//! one of this machine's own addresses is answered with the same data.
//! A destination-unreachable quotes the header of the packet it is about:
//! when that was a UDP datagram, the socket it came from is told -
//! `ECONNREFUSED` for a port nobody has, `EHOSTUNREACH` or `ENETUNREACH`
//! for the rest - at its next call.
//!
//! **Errors out**: a port-unreachable for a UDP datagram to a port
//! nobody is bound to - never for a datagram sent to many, from no
//! address, or that was itself an ICMP error, so no error ever answers an
//! error.
//!
//! **Raw sockets** (`SOCK_RAW`, `IPPROTO_ICMP`) send what the program
//! gives them as the ICMP message - header and checksum are the
//! program's - behind an IPv4 header the stack makes.

const sdk = @import("sdk");
const Address = @import("../ip6/address.zig").Address;
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _route = @import("../route/_route.zig");
const _ip = @import("../ip/_ip.zig");
const _udp = @import("../udp/_udp.zig");
const _socket = @import("../socket/_socket.zig");
const Socket = _socket.Socket;

pub const header_bytes = 8;
const protocol: u8 = @intCast(bsd.IPPROTO_ICMP);

pub const echo_reply: u8 = 0;
pub const destination_unreachable: u8 = 3;
pub const echo_request: u8 = 8;

pub const code_network: u8 = 0;
pub const code_host: u8 = 1;
pub const code_port: u8 = 3;

/// Whether a message of `kind` is an error, which is never answered with
/// another.
fn isError(kind: u8) bool {
    return kind != echo_reply and kind != echo_request and kind != 13 and kind != 14;
}

/// An ICMP message that came in, the frame starting at it; `header` is
/// the IPv4 header in front of it.
pub fn input(stack: *StackBase, interface: *Interface, frame: *Frame, header: _ip.Header) void {
    _ = interface;
    const sys = stack.sys_base;
    stack.counts.icmp_received += 1;
    const message = frame.bytes();
    if (message.len < header_bytes or _ip.finish(_ip.sum(0, message)) != 0) {
        stack.counts.icmp_bad += 1;
        return stack.frames.give(sys, frame);
    }
    deliverRaw(stack, frame, header);
    switch (message[0]) {
        echo_request => {
            // Answered only when it was sent to this machine alone.
            if (_netif.isBroadcast(stack, header.destination)) return stack.frames.give(sys, frame);
            const hop = _route.lookup(stack, header.source) orelse return stack.frames.give(sys, frame);
            message[0] = echo_reply;
            _ip.put16(message, 2, 0);
            _ip.put16(message, 2, _ip.finish(_ip.sum(0, message)));
            stack.counts.icmp_echoes_answered += 1;
            _ = _ip.output(stack, frame, header.destination, header.source, protocol, hop);
        },
        destination_unreachable => {
            reportUnreachable(stack, message);
            stack.frames.give(sys, frame);
        },
        else => stack.frames.give(sys, frame),
    }
}

/// A destination-unreachable: the socket the quoted datagram came from
/// told why it went nowhere.
fn reportUnreachable(stack: *StackBase, message: []const u8) void {
    const quoted = message[header_bytes..];
    if (quoted.len < _ip.header_bytes or quoted[0] >> 4 != 4) return;
    const quoted_length: u32 = @as(u32, quoted[0] & 0xF) * 4;
    if (quoted_length < _ip.header_bytes or quoted.len < quoted_length + 4) return;
    if (quoted[9] != @as(u8, @intCast(bsd.IPPROTO_UDP))) return;
    const local_address = Address.fromV4(_ip.get32(quoted, 12));
    const remote_address = Address.fromV4(_ip.get32(quoted, 16));
    const local_port = _ip.get16(quoted, quoted_length);
    const remote_port = _ip.get16(quoted, quoted_length + 2);
    const socket = sender(stack, local_address, local_port, remote_address, remote_port) orelse return;
    const errno: i32 = switch (message[1]) {
        code_port => bsd.ECONNREFUSED,
        code_network => bsd.ENETUNREACH,
        else => bsd.EHOSTUNREACH,
    };
    _socket.setError(socket, errno);
}

/// The datagram socket a datagram from `local_port` to
/// `remote_address:remote_port` went out of.
fn sender(stack: *StackBase, local_address: Address, local_port: u16, remote_address: Address, remote_port: u16) ?*Socket {
    var it = stack.sockets.iterator();
    while (it.next()) |node| {
        const socket = _socket.fromNode(node);
        if (socket.socket_type != bsd.SOCK_DGRAM or socket.local_port != local_port) continue;
        if (!_socket.takes(socket, local_address)) continue;
        if (socket.flags & _socket.connected != 0 and (!socket.remote_address.eql(remote_address) or socket.remote_port != remote_port)) continue;
        return socket;
    }
    return null;
}

/// A copy of the message, IPv4 header and all, for every raw ICMP socket
/// with room in its queue.
fn deliverRaw(stack: *StackBase, frame: *Frame, header: _ip.Header) void {
    const sys = stack.sys_base;
    var it = stack.sockets.iterator();
    while (it.next()) |node| {
        const socket = _socket.fromNode(node);
        if (socket.socket_type != bsd.SOCK_RAW or socket.protocol != bsd.IPPROTO_ICMP) continue;
        const packet_length = frame.length + header.header_length;
        const copy = stack.frames.take(sys) orelse return;
        if (!_socket.hasRoom(socket, copy.cost())) {
            stack.frames.give(sys, copy);
            continue;
        }
        if (packet_length > copy.capacity - copy.start) {
            stack.frames.give(sys, copy);
            continue;
        }
        const packet = frame.room()[frame.start - header.header_length ..][0..packet_length];
        @memcpy(copy.room()[copy.start..][0..packet_length], packet);
        copy.length = packet_length;
        copy.from_address = Address.fromV4(header.source);
        sys.AddTail(&socket.receive, &copy.node);
        socket.receive_bytes += copy.cost();
        _socket.wake(socket, bsd.FD_READ);
    }
}

/// A destination-unreachable of `code` for the packet in `frame`, which
/// starts at its IPv4 header: sent back to its source, quoting the header
/// and the first 8 bytes behind it. The frame stays the caller's.
pub fn sendUnreachable(stack: *StackBase, frame: *Frame, header: _ip.Header, code: u8) void {
    const packet = frame.bytes();
    if (header.source == 0 or header.source == bsd.INADDR_BROADCAST or header.source >> 28 == 0xE) return;
    if (_netif.isBroadcast(stack, header.destination)) return;
    if (header.protocol == protocol) {
        const behind = packet[header.header_length..];
        if (behind.len == 0 or isError(behind[0])) return;
    }
    const hop = _route.lookup(stack, header.source) orelse return;
    const quoted_length: u32 = @min(@as(u32, @intCast(packet.len)), header.header_length + 8);
    const answer = stack.frames.take(stack.sys_base) orelse return;
    const message = answer.room()[answer.start..][0 .. header_bytes + quoted_length];
    answer.length = header_bytes + quoted_length;
    message[0] = destination_unreachable;
    message[1] = code;
    _ip.put16(message, 2, 0);
    _ip.put32(message, 4, 0);
    @memcpy(message[header_bytes..], packet[0..quoted_length]);
    _ip.put16(message, 2, _ip.finish(_ip.sum(0, message)));
    stack.counts.icmp_errors_sent += 1;
    _ = _ip.output(stack, answer, header.destination, header.source, protocol, hop);
}

/// `data`, an ICMP message a raw socket was given, sent to `destination`:
/// 0, or the errno that says why not.
pub fn output(stack: *StackBase, socket: *Socket, to: Address, data: []const u8) i32 {
    const destination = to.v4();
    const hop = _route.lookup(stack, destination) orelse return bsd.ENETUNREACH;
    if (data.len < header_bytes) return bsd.EINVAL;
    if (data.len + _ip.header_bytes > hop.interface.mtu) return bsd.EMSGSIZE;
    const broadcast = destination == bsd.INADDR_BROADCAST or destination == hop.interface.broadcast;
    if (broadcast and socket.flags & _socket.broadcast_allowed == 0) return bsd.EACCES;
    const source = if (!socket.local_address.isUnspecified()) socket.local_address.v4() else hop.interface.address;
    const frame = stack.frames.take(stack.sys_base) orelse return bsd.ENOBUFS;
    @memcpy(frame.room()[frame.start..][0..data.len], data);
    frame.length = @intCast(data.len);
    return _ip.output(stack, frame, source, destination, protocol, hop);
}
