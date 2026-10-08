// SPDX-License-Identifier: MIT
//! UDP (RFC 768): datagrams to and from ports.
//!
//! **To a group** (IPv4 or IPv6 multicast), a datagram goes to every
//! socket bound to its port that is in the group on the interface it came
//! in on, each a copy of its own; when a socket sends to a group its
//! interface is in, this machine's members get a copy too, unless
//! IP_MULTICAST_LOOP or IPV6_MULTICAST_LOOP says no. A datagram to a group
//! goes out with the socket's multicast hop limit or time to live (1
//! unless set) and of its multicast interface, if it named one.
//!
//! **In**: the header inside the packet, its length at least the header
//! and at most the packet, and its checksum right unless it is 0, which
//! over IPv4 means the sender made none (over IPv6 a checksum is always
//! there, and 0 is refused). The datagram goes to the socket bound to
//! its destination port that fits it best - bound to exactly its
//! destination address before bound to any, connected to exactly its
//! source before not connected - and waits in that socket's queue until
//! it is read, unless the queue already holds `SO_RCVBUF` bytes, when it
//! is dropped and counted.
//!
//! **Out**: a socket that is not bound yet is given a port of its own
//! first. The source address is the one the socket is bound to, or the
//! address of the interface the route picks. A datagram larger than the
//! path takes is refused over IPv4, and goes in fragments over IPv6.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const _frame = @import("../frame/_frame.zig");
const Frame = _frame.Frame;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _route = @import("../route/_route.zig");
const _ip = @import("../ip/_ip.zig");
const _socket = @import("../socket/_socket.zig");
const _icmp = @import("../icmp/_icmp.zig");
const _dhcp = @import("../dhcp/_dhcp.zig");
const _dhcp6 = @import("../dhcp6/_dhcp6.zig");
const Socket = _socket.Socket;
const Address = @import("../ip6/address.zig").Address;
const _inet = @import("../inet/_inet.zig");
const Packet = _inet.Packet;
const _hook = @import("../hook/_hook.zig");

pub const header_bytes = 8;
const protocol: u8 = @intCast(bsd.IPPROTO_UDP);
/// The most data one datagram carries: 65535 less the IPv4 and UDP
/// headers.
pub const data_max: u32 = 65535 - _ip.header_bytes - header_bytes;

pub fn input(stack: *StackBase, interface: *Interface, frame: *Frame, packet: Packet) void {
    const sys = stack.sys_base;
    const datagram = frame.bytes();
    if (datagram.len < header_bytes) return drop(stack, frame, &stack.counts.udp_bad);
    const length = _ip.get16(datagram, 4);
    if (length < header_bytes or length > datagram.len) return drop(stack, frame, &stack.counts.udp_bad);
    // IPv6 has no datagram without a checksum (RFC 8200, 8.1).
    if (_ip.get16(datagram, 6) == 0 and !packet.source.isV4()) return drop(stack, frame, &stack.counts.udp_bad);
    if (_ip.get16(datagram, 6) != 0) {
        const total = _ip.sum(_inet.pseudoSum(packet.source, packet.destination, protocol, length), datagram[0..length]);
        if (_ip.finish(total) != 0) return drop(stack, frame, &stack.counts.udp_bad);
    }
    const source_port = _ip.get16(datagram, 0);
    const destination_port = _ip.get16(datagram, 2);
    if (packet.source.isV4() and destination_port == _dhcp.client_port and source_port == _dhcp.server_port and
        _dhcp.input(stack, interface, datagram[header_bytes..length]))
    {
        return stack.frames.give(stack.sys_base, frame);
    }
    if (!packet.source.isV4() and destination_port == _dhcp6.client_port and source_port == _dhcp6.server_port and
        _dhcp6.input(stack, interface, datagram[header_bytes..length]))
    {
        return stack.frames.give(stack.sys_base, frame);
    }
    if (_inet.isGroup(packet.destination)) {
        if (asked(stack, interface, frame, packet, datagram[0..length], bsd.PACKET_BELONGS_BOUND) != .pass) return stack.frames.give(sys, frame);
        return toGroup(stack, interface, frame, packet, length, source_port, destination_port);
    }
    const found = find(stack, packet.destination, destination_port, packet.source, source_port);
    switch (asked(stack, interface, frame, packet, datagram[0..length], if (found != null) bsd.PACKET_BELONGS_BOUND else bsd.PACKET_BELONGS_NONE)) {
        .pass => {},
        .drop => return stack.frames.give(sys, frame),
        .refuse => {
            _ = frame.push(packet.header_length);
            _inet.sendUnreachable(stack, interface, frame, packet, .port);
            return stack.frames.give(sys, frame);
        },
    }
    const socket = found orelse {
        // Nobody is bound there: the sender is told, unless it sent to
        // many.
        _ = frame.push(packet.header_length);
        _inet.sendUnreachable(stack, interface, frame, packet, .port);
        return drop(stack, frame, &stack.counts.udp_no_port);
    };
    if (!_socket.hasRoom(socket, frame.cost())) return drop(stack, frame, &stack.counts.udp_full);
    frame.trim(length);
    frame.pull(header_bytes);
    frame.from_address = packet.source;
    frame.from_interface = interface;
    frame.from_port = source_port;
    frame.hop_limit = packet.hop_limit;
    sys.AddTail(&socket.receive, &frame.node);
    socket.receive_bytes += frame.cost();
    stack.counts.udp_received += 1;
    _socket.wake(socket, bsd.FD_READ);
}

/// What the packet hooks say of a datagram that came in. A copy of this
/// machine's own datagram to a group, looped back to its members, has no
/// IP header in front and is not asked about.
fn asked(stack: *StackBase, interface: *Interface, frame: *Frame, packet: Packet, datagram: []const u8, belongs: u8) _hook.Verdict {
    if (stack.hooks_in.isEmpty() or packet.header_length == 0) return .pass;
    return _hook.ask(stack, bsd.PH_IN, .{
        .interface = interface,
        .source = packet.source,
        .destination = packet.destination,
        .protocol = protocol,
        .belongs = belongs,
        .data = datagram,
        .frame = frame,
        .header_length = packet.header_length,
    });
}

/// A copy of a datagram to a group, from its UDP header on, handed to
/// this machine's members as if it had come in on `interface` with
/// `hop_limit`.
fn loopBack(stack: *StackBase, frame: *Frame, source: Address, destination: Address, interface: *Interface, hop_limit: u8) void {
    const sys = stack.sys_base;
    const copy = (if (frame.length <= _frame.buffer_bytes - _frame.headroom) stack.frames.take(sys) else stack.frames.takeLarge(sys, _frame.headroom + frame.length)) orelse return;
    @memcpy(copy.room()[copy.start..][0..frame.length], frame.bytes());
    copy.length = frame.length;
    input(stack, interface, copy, .{ .source = source, .destination = destination, .protocol = protocol, .header_length = 0, .hop_limit = hop_limit, .arrived = interface });
}

/// A datagram to a group, to each member socket bound to its port on the
/// interface it came in on: copies, and the frame itself to the last.
fn toGroup(stack: *StackBase, interface: *Interface, frame: *Frame, packet: Packet, length: u32, source_port: u16, destination_port: u16) void {
    const sys = stack.sys_base;
    frame.trim(length);
    frame.pull(header_bytes);
    var last: ?*Socket = null;
    var it = stack.sockets.iterator();
    while (it.next()) |node| {
        const socket = _socket.fromNode(node);
        if (socket.socket_type != bsd.SOCK_DGRAM or socket.local_port != destination_port) continue;
        if (!_socket.takes(socket, packet.destination) or !_socket.isMember(socket, packet.destination, interface)) continue;
        if (socket.flags & _socket.connected != 0 and (!socket.remote_address.eql(packet.source) or socket.remote_port != source_port)) continue;
        if (last) |earlier| {
            const copy = (if (frame.length <= _frame.buffer_bytes - _frame.headroom) stack.frames.take(sys) else stack.frames.takeLarge(sys, _frame.headroom + frame.length)) orelse break;
            @memcpy(copy.room()[copy.start..][0..frame.length], frame.bytes());
            copy.length = frame.length;
            queue(stack, earlier, copy, packet, source_port, interface);
        }
        last = socket;
    }
    const socket = last orelse return drop(stack, frame, &stack.counts.udp_no_port);
    queue(stack, socket, frame, packet, source_port, interface);
}

/// A datagram, its header off, into `socket`'s queue - or dropped when
/// the queue is full.
fn queue(stack: *StackBase, socket: *Socket, frame: *Frame, packet: Packet, source_port: u16, interface: *Interface) void {
    if (!_socket.hasRoom(socket, frame.cost())) return drop(stack, frame, &stack.counts.udp_full);
    const source = packet.source;
    frame.hop_limit = packet.hop_limit;
    frame.from_address = source;
    frame.from_port = source_port;
    frame.from_interface = interface;
    stack.sys_base.AddTail(&socket.receive, &frame.node);
    socket.receive_bytes += frame.cost();
    stack.counts.udp_received += 1;
    _socket.wake(socket, bsd.FD_READ);
}

fn drop(stack: *StackBase, frame: *Frame, count: *u32) void {
    count.* += 1;
    stack.frames.give(stack.sys_base, frame);
}

/// The datagram socket a datagram from `remote_address:remote_port` to
/// `local_address:local_port` belongs to, the best fitting one: bound to
/// exactly its address before bound to none, whose family then has to
/// take it (`_socket.takes`).
pub fn find(stack: *StackBase, local_address: Address, local_port: u16, remote_address: Address, remote_port: u16) ?*Socket {
    var best: ?*Socket = null;
    var best_fit: u32 = 0;
    var it = stack.sockets.iterator();
    while (it.next()) |node| {
        const socket = _socket.fromNode(node);
        if (socket.socket_type != bsd.SOCK_DGRAM or socket.local_port != local_port) continue;
        if (!_socket.takes(socket, local_address)) continue;
        var fit: u32 = 1;
        if (!socket.local_address.isUnspecified()) fit += 1;
        if (socket.flags & _socket.connected != 0) {
            if (!socket.remote_address.eql(remote_address) or socket.remote_port != remote_port) continue;
            fit += 2;
        }
        if (fit > best_fit) {
            best = socket;
            best_fit = fit;
        }
    }
    return best;
}

/// `data` sent from `socket` to `destination:port`, a link-local
/// destination on `scope` (the socket's own when null): 0, or the errno
/// that says why not.
pub fn output(stack: *StackBase, socket: *Socket, destination: Address, port: u16, scope: ?*Interface, data: []const u8) i32 {
    const group = _inet.isGroup(destination);
    const named = scope orelse (if (group) socket.multicast_interface orelse socket.scope else socket.scope);
    const path = _inet.route(stack, destination, named) orelse return bsd.ENETUNREACH;
    // IPv4 sends nothing in fragments; IPv6 does, from a frame of its own
    // for a datagram larger than one.
    const fits = data.len + header_bytes + _inet.headerBytes(destination) <= path.mtu;
    if (!fits and destination.isV4()) return bsd.EMSGSIZE;
    if (_inet.isBroadcast(destination, path) and socket.flags & _socket.broadcast_allowed == 0) return bsd.EACCES;
    if (socket.flags & _socket.bound == 0) {
        if (!_socket.bindAnyPort(stack, socket)) return bsd.EADDRNOTAVAIL;
    }
    const source = if (!socket.local_address.isUnspecified()) socket.local_address else (_inet.sourceFor(path, destination) orelse return bsd.EADDRNOTAVAIL);
    const frame = (if (fits) stack.frames.take(stack.sys_base) else stack.frames.takeLarge(stack.sys_base, _frame.headroom + @as(u32, @intCast(data.len)) + header_bytes)) orelse return bsd.ENOBUFS;
    @memcpy(frame.room()[frame.start..][0..data.len], data);
    frame.length = @intCast(data.len);
    const header = frame.push(header_bytes);
    const length: u16 = @intCast(frame.length);
    _ip.put16(header, 0, socket.local_port);
    _ip.put16(header, 2, port);
    _ip.put16(header, 4, length);
    _ip.put16(header, 6, 0);
    var checksum = _ip.finish(_ip.sum(_inet.pseudoSum(source, destination, protocol, length), frame.bytes()));
    // A checksum that comes out 0 is sent as its other form, since 0
    // means none.
    if (checksum == 0) checksum = 0xFFFF;
    _ip.put16(header, 6, checksum);
    stack.counts.udp_sent += 1;
    if (group) {
        // This machine's own members of the group, on the interface it
        // goes out of, get it as the link would bring it back.
        if (socket.multicast_no_loop == 0 and _inet.hasMembers(path.interface, destination)) {
            loopBack(stack, frame, source, destination, path.interface, if (socket.multicast_hops == 0) 1 else socket.multicast_hops);
        }
        return _inet.output(stack, frame, source, destination, protocol, path, socket.multicast_hops);
    }
    return _inet.output(stack, frame, source, destination, protocol, path, socket.hop_limit);
}
