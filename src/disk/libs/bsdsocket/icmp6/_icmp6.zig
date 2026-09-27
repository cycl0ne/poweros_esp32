// SPDX-License-Identifier: MIT
//! ICMPv6 (RFC 4443): echoes answered, errors told to what they concern,
//! and errors sent for packets nothing here takes.
//!
//! **In**: at least the 4-byte header, and a checksum over the pseudo
//! header and the message that checks out. An echo request is answered
//! with the same data - sent to a group, too, from the address the reply
//! is best sent from. A destination-unreachable quotes the packet it is
//! about: when that was a UDP datagram, the socket it came from is told
//! (`ECONNREFUSED` for a port nobody has, `EHOSTUNREACH` for the rest)
//! at its next call. A packet-too-big lowers the path MTU of the
//! destination it quotes (`ip6/_ip6.zig`), and every TCP connection to
//! it sends smaller segments from then on.
//!
//! A copy of every message that checks out goes to each raw ICMPv6
//! socket that takes its destination - without the IPv6 header, as RFC
//! 3542 has it. Neighbor Discovery's messages go to `nd/_nd.zig`, MLD's
//! queries to `nd/mld.zig`.
//!
//! **Raw sockets** (`SOCK_RAW`, `IPPROTO_ICMPV6`) send what the program
//! gives them as the ICMPv6 message behind an IPv6 header the stack
//! makes; the stack makes the checksum, since the program cannot know
//! the source address it goes from.
//!
//! **Errors out** (`sendError`): never about an ICMPv6 error, a packet
//! from the unspecified address or a group, or a packet sent to a group -
//! except a packet-too-big and a parameter problem about an option whose
//! bits ask for one. The message quotes as much of the packet as fits in
//! IPv6's least MTU, 1280 bytes. At most `burst` errors go at once, and
//! then one per `refill_us` (RFC 4443, 2.4 f): what the limit holds back
//! is counted, not sent.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const _frame = @import("../frame/_frame.zig");
const Frame = _frame.Frame;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _ip = @import("../ip/_ip.zig");
const _ip6 = @import("../ip6/_ip6.zig");
const _inet = @import("../inet/_inet.zig");
const _timer = @import("../timer/_timer.zig");
const _socket = @import("../socket/_socket.zig");
const Socket = _socket.Socket;
const _tcp = @import("../tcp/_tcp.zig");
const _nd = @import("../nd/_nd.zig");
const mld = @import("../nd/mld.zig");
const Address = @import("../ip6/address.zig").Address;

pub const header_bytes = 8;
const protocol = _ip6.protocol_icmp6;

pub const destination_unreachable: u8 = 1;
pub const packet_too_big: u8 = 2;
pub const time_exceeded: u8 = 3;
pub const parameter_problem: u8 = 4;
pub const echo_request: u8 = 128;
pub const echo_reply: u8 = 129;

/// Destination-unreachable's codes.
pub const code_no_route: u8 = 0;
pub const code_address: u8 = 3;
pub const code_port: u8 = 4;
/// Time-exceeded's: the hop limit ran out, reassembly ran out of time.
pub const code_hop_limit: u8 = 0;
pub const code_reassembly: u8 = 1;

/// The errors that may go at once, and how often one more may.
pub const burst: u32 = 10;
pub const refill_us: u64 = 100_000;

/// What the rate limit has left.
pub const Limit = extern struct {
    tokens: u32 = burst,
    refilled: u64 align(4) = 0,
};

/// An ICMPv6 message that came in, the frame starting at it; `packet` is
/// what its IPv6 headers said.
pub fn input(stack: *StackBase, interface: *Interface, frame: *Frame, packet: _inet.Packet) void {
    const sys = stack.sys_base;
    stack.counts.icmp6_received += 1;
    const message = frame.bytes();
    if (message.len < 4 or _ip.finish(_ip.sum(_inet.pseudoSum(packet.source, packet.destination, protocol, @intCast(message.len)), message)) != 0) {
        stack.counts.icmp6_bad += 1;
        return stack.frames.give(sys, frame);
    }
    deliverRaw(stack, frame, packet);
    switch (message[0]) {
        echo_request => {
            if (message.len < header_bytes or packet.source.isUnspecified()) return stack.frames.give(sys, frame);
            const path = _inet.route(stack, packet.source, interface) orelse return stack.frames.give(sys, frame);
            const source = if (packet.destination.isMulticast())
                (_inet.sourceFor(path, packet.source) orelse return stack.frames.give(sys, frame))
            else
                packet.destination;
            message[0] = echo_reply;
            message[1] = 0;
            _ip.put16(message, 2, 0);
            _ip.put16(message, 2, _ip.finish(_ip.sum(_inet.pseudoSum(source, packet.source, protocol, @intCast(message.len)), message)));
            stack.counts.icmp6_echoes_answered += 1;
            _ = _ip6.output(stack, frame, source, packet.source, protocol, interface.ip6.hop_limit, path);
        },
        destination_unreachable => {
            if (message.len >= header_bytes) reportUnreachable(stack, message[1], message[header_bytes..]);
            stack.frames.give(sys, frame);
        },
        packet_too_big => {
            if (message.len >= header_bytes + _ip6.header_bytes) {
                const quoted = message[header_bytes..];
                const destination: Address = .{ .bytes = quoted[24..40].* };
                const mtu = _ip6.learnMtu(stack, destination, _ip.get32(message, 4), _timer.clock(stack));
                lowerMss(stack, destination, mtu);
            }
            stack.frames.give(sys, frame);
        },
        _nd.router_solicitation..._nd.redirect => _nd.input(stack, interface, frame, packet, _timer.clock(stack)),
        mld.query => {
            mld.input(stack, interface, message, packet);
            stack.frames.give(sys, frame);
        },
        else => stack.frames.give(sys, frame),
    }
}

/// Where the transport's header starts in a quoted packet, and which
/// transport it is: the quoted extension headers walked as far as they
/// were quoted.
fn quotedTransport(quoted: []const u8) ?struct { at: u32, protocol: u8 } {
    if (quoted.len < _ip6.header_bytes or quoted[0] >> 4 != 6) return null;
    var next = quoted[6];
    var at: u32 = _ip6.header_bytes;
    while (true) {
        switch (next) {
            _ip6.hop_by_hop, _ip6.routing, _ip6.destination_options => {
                if (at + 2 > quoted.len) return null;
                next = quoted[at];
                at += (@as(u32, quoted[at + 1]) + 1) * 8;
            },
            _ip6.fragment => {
                if (at + 8 > quoted.len) return null;
                // Only the first piece quotes the transport's header.
                if (_ip.get16(quoted, at + 2) & 0xFFF8 != 0) return null;
                next = quoted[at];
                at += 8;
            },
            else => return .{ .at = at, .protocol = next },
        }
    }
}

/// A destination-unreachable: the socket the quoted datagram came from
/// told why it went nowhere.
fn reportUnreachable(stack: *StackBase, code: u8, quoted: []const u8) void {
    const transport = quotedTransport(quoted) orelse return;
    if (transport.protocol != @as(u8, @intCast(bsd.IPPROTO_UDP)) or quoted.len < transport.at + 4) return;
    const local_address: Address = .{ .bytes = quoted[8..24].* };
    const remote_address: Address = .{ .bytes = quoted[24..40].* };
    const local_port = _ip.get16(quoted, transport.at);
    const remote_port = _ip.get16(quoted, transport.at + 2);
    var it = stack.sockets.iterator();
    while (it.next()) |node| {
        const socket = _socket.fromNode(node);
        if (socket.socket_type != bsd.SOCK_DGRAM or socket.local_port != local_port) continue;
        if (!_socket.takes(socket, local_address)) continue;
        if (socket.flags & _socket.connected != 0 and (!socket.remote_address.eql(remote_address) or socket.remote_port != remote_port)) continue;
        _socket.setError(socket, if (code == code_port) bsd.ECONNREFUSED else bsd.EHOSTUNREACH);
        return;
    }
}

/// Every TCP connection to `destination` held to segments that fit a
/// path of `mtu`.
fn lowerMss(stack: *StackBase, destination: Address, mtu: u32) void {
    const most = mtu - _ip6.header_bytes - _tcp.header_bytes;
    var it = stack.sockets.iterator();
    while (it.next()) |node| {
        const socket = _socket.fromNode(node);
        if (socket.socket_type != bsd.SOCK_STREAM or !socket.remote_address.eql(destination)) continue;
        const tcb = _tcp.of(socket);
        if (tcb.mss > most) tcb.mss = most;
    }
}

/// Whether the rate limit lets one more error go now.
fn allowed(stack: *StackBase) bool {
    const limit = &stack.icmp6_limit;
    const now = _timer.clock(stack);
    if (now > limit.refilled) {
        const earned = (now - limit.refilled) / refill_us;
        if (earned > 0) {
            limit.tokens = @intCast(@min(@as(u64, burst), limit.tokens + earned));
            limit.refilled += earned * refill_us;
        }
    }
    if (limit.tokens == 0) {
        stack.counts.icmp6_errors_limited += 1;
        return false;
    }
    limit.tokens -= 1;
    return true;
}

/// An error of `kind` and `code` about the packet in `frame`, which came
/// in on `interface` and starts at its IPv6 header: sent back to its
/// source with `parameter` (the pointer, or the MTU) and as much of the
/// packet as fits. The frame stays the caller's.
pub fn sendError(stack: *StackBase, interface: *Interface, frame: *Frame, packet: _inet.Packet, kind: u8, code: u8, parameter: u32) void {
    if (packet.source.isUnspecified() or packet.source.isMulticast()) return;
    if (packet.destination.isMulticast() and kind != packet_too_big and !(kind == parameter_problem and code == _ip6.problem_option)) return;
    const bytes = frame.bytes();
    if (packet.protocol == protocol) {
        const behind = bytes[@min(bytes.len, packet.header_length)..];
        if (behind.len == 0 or behind[0] < 128) return;
    }
    const path = _inet.route(stack, packet.source, interface) orelse return;
    const source = if (!packet.destination.isMulticast() and _ip6.owner(stack, packet.destination) != null)
        packet.destination
    else
        (_inet.sourceFor(path, packet.source) orelse return);
    if (!allowed(stack)) return;
    const room = @min(_ip6.minimum_mtu, path.mtu) - _ip6.header_bytes - header_bytes;
    const quoted_length: u32 = @min(@as(u32, @intCast(bytes.len)), room);
    const answer = stack.frames.take(stack.sys_base) orelse return;
    const message = answer.room()[answer.start..][0 .. header_bytes + quoted_length];
    answer.length = header_bytes + quoted_length;
    message[0] = kind;
    message[1] = code;
    _ip.put16(message, 2, 0);
    _ip.put32(message, 4, parameter);
    @memcpy(message[header_bytes..], bytes[0..quoted_length]);
    _ip.put16(message, 2, _ip.finish(_ip.sum(_inet.pseudoSum(source, packet.source, protocol, answer.length), message)));
    stack.counts.icmp6_errors_sent += 1;
    _ = _ip6.output(stack, answer, source, packet.source, protocol, interface.ip6.hop_limit, path);
}

/// A copy of the message for every raw ICMPv6 socket that takes it and
/// has room in its queue.
fn deliverRaw(stack: *StackBase, frame: *Frame, packet: _inet.Packet) void {
    const sys = stack.sys_base;
    var it = stack.sockets.iterator();
    while (it.next()) |node| {
        const socket = _socket.fromNode(node);
        if (socket.socket_type != bsd.SOCK_RAW or socket.protocol != bsd.IPPROTO_ICMPV6) continue;
        if (!_socket.takes(socket, packet.destination)) continue;
        if (socket.flags & _socket.connected != 0 and !socket.remote_address.eql(packet.source)) continue;
        // A message put back together from fragments may be larger than a
        // frame: its copy gets a frame of its size.
        const copy = (if (frame.length <= _frame.buffer_bytes - _frame.headroom) stack.frames.take(sys) else stack.frames.takeLarge(sys, _frame.headroom + frame.length)) orelse return;
        if (!_socket.hasRoom(socket, copy.cost())) {
            stack.frames.give(sys, copy);
            continue;
        }
        @memcpy(copy.room()[copy.start..][0..frame.length], frame.bytes());
        copy.length = frame.length;
        copy.from_address = packet.source;
        copy.from_interface = packet.arrived;
        sys.AddTail(&socket.receive, &copy.node);
        socket.receive_bytes += copy.cost();
        _socket.wake(socket, bsd.FD_READ);
    }
}

/// `data`, an ICMPv6 message a raw socket was given, sent to
/// `destination`, a link-local one on `scope` (the socket's own when
/// null), with the checksum made here: 0, or the errno that says why not.
pub fn output(stack: *StackBase, socket: *Socket, destination: Address, scope: ?*Interface, data: []const u8) i32 {
    if (destination.isV4() or destination.isUnspecified()) return bsd.EAFNOSUPPORT;
    if (data.len < 4) return bsd.EINVAL;
    const path = _inet.route(stack, destination, scope orelse socket.scope) orelse return bsd.ENETUNREACH;
    if (data.len > 65535 - 8) return bsd.EMSGSIZE;
    const source = if (!socket.local_address.isUnspecified()) socket.local_address else (_inet.sourceFor(path, destination) orelse return bsd.EADDRNOTAVAIL);
    // Larger than the path takes, it goes in fragments, from a frame of
    // its own.
    const fits = data.len + _ip6.header_bytes <= path.mtu;
    const frame = (if (fits) stack.frames.take(stack.sys_base) else stack.frames.takeLarge(stack.sys_base, _frame.headroom + @as(u32, @intCast(data.len)))) orelse return bsd.ENOBUFS;
    const message = frame.room()[frame.start..][0..data.len];
    @memcpy(message, data);
    frame.length = @intCast(data.len);
    _ip.put16(message, 2, 0);
    _ip.put16(message, 2, _ip.finish(_ip.sum(_inet.pseudoSum(source, destination, protocol, frame.length), message)));
    return _inet.output(stack, frame, source, destination, protocol, path, socket.hop_limit);
}
