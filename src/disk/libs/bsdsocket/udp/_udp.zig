// SPDX-License-Identifier: MIT
//! UDP (RFC 768): datagrams to and from ports.
//!
//! **In**: the header inside the packet, its length at least the header
//! and at most the packet, and its checksum right unless it is 0, which
//! means the sender made none. The datagram goes to the socket bound to
//! its destination port that fits it best - bound to exactly its
//! destination address before bound to any, connected to exactly its
//! source before not connected - and waits in that socket's queue until
//! it is read, unless the queue already holds `SO_RCVBUF` bytes, when it
//! is dropped and counted.
//!
//! **Out**: a socket that is not bound yet is given a port of its own
//! first. The source address is the one the socket is bound to, or the
//! address of the interface the route picks. A datagram larger than that
//! interface takes is refused: nothing is fragmented going out.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _route = @import("../route/_route.zig");
const _ip = @import("../ip/_ip.zig");
const _socket = @import("../socket/_socket.zig");
const _icmp = @import("../icmp/_icmp.zig");
const Socket = _socket.Socket;

pub const header_bytes = 8;
const protocol: u8 = @intCast(bsd.IPPROTO_UDP);
/// The most data one datagram carries: 65535 less the IPv4 and UDP
/// headers.
pub const data_max: u32 = 65535 - _ip.header_bytes - header_bytes;

pub fn input(stack: *StackBase, interface: *Interface, frame: *Frame, header: _ip.Header) void {
    _ = interface;
    const sys = stack.sys_base;
    const datagram = frame.bytes();
    if (datagram.len < header_bytes) return drop(stack, frame, &stack.counts.udp_bad);
    const length = _ip.get16(datagram, 4);
    if (length < header_bytes or length > datagram.len) return drop(stack, frame, &stack.counts.udp_bad);
    if (_ip.get16(datagram, 6) != 0) {
        const total = _ip.sum(_ip.pseudoSum(header.source, header.destination, protocol, length), datagram[0..length]);
        if (_ip.finish(total) != 0) return drop(stack, frame, &stack.counts.udp_bad);
    }
    const source_port = _ip.get16(datagram, 0);
    const destination_port = _ip.get16(datagram, 2);
    const socket = find(stack, header.destination, destination_port, header.source, source_port) orelse {
        // Nobody is bound there: the sender is told, unless it sent to
        // many.
        _ = frame.push(header.header_length);
        _icmp.sendUnreachable(stack, frame, header, _icmp.code_port);
        return drop(stack, frame, &stack.counts.udp_no_port);
    };
    const data_length = length - header_bytes;
    if (socket.receive_bytes + data_length > socket.receive_limit) return drop(stack, frame, &stack.counts.udp_full);
    frame.trim(length);
    frame.pull(header_bytes);
    frame.from_address = header.source;
    frame.from_port = source_port;
    sys.AddTail(&socket.receive, &frame.node);
    socket.receive_bytes += data_length;
    stack.counts.udp_received += 1;
    _socket.wake(socket, bsd.FD_READ);
}

fn drop(stack: *StackBase, frame: *Frame, count: *u32) void {
    count.* += 1;
    stack.frames.give(stack.sys_base, frame);
}

/// The datagram socket a datagram from `remote_address:remote_port` to
/// `local_address:local_port` belongs to, the best fitting one.
pub fn find(stack: *StackBase, local_address: u32, local_port: u16, remote_address: u32, remote_port: u16) ?*Socket {
    var best: ?*Socket = null;
    var best_fit: u32 = 0;
    var it = stack.sockets.iterator();
    while (it.next()) |node| {
        const socket = _socket.fromNode(node);
        if (socket.socket_type != bsd.SOCK_DGRAM or socket.local_port != local_port) continue;
        var fit: u32 = 1;
        if (socket.local_address != bsd.INADDR_ANY) {
            if (socket.local_address != local_address) continue;
            fit += 1;
        }
        if (socket.flags & _socket.connected != 0) {
            if (socket.remote_address != remote_address or socket.remote_port != remote_port) continue;
            fit += 2;
        }
        if (fit > best_fit) {
            best = socket;
            best_fit = fit;
        }
    }
    return best;
}

/// `data` sent from `socket` to `destination:port`: 0, or the errno that
/// says why not.
pub fn output(stack: *StackBase, socket: *Socket, destination: u32, port: u16, data: []const u8) i32 {
    const hop = _route.lookup(stack, destination) orelse return bsd.ENETUNREACH;
    if (data.len + header_bytes + _ip.header_bytes > hop.interface.mtu) return bsd.EMSGSIZE;
    const broadcast = destination == bsd.INADDR_BROADCAST or destination == hop.interface.broadcast;
    if (broadcast and socket.flags & _socket.broadcast_allowed == 0) return bsd.EACCES;
    if (socket.flags & _socket.bound == 0) {
        if (!_socket.bindAnyPort(stack, socket)) return bsd.EADDRNOTAVAIL;
    }
    const source = if (socket.local_address != bsd.INADDR_ANY) socket.local_address else hop.interface.address;
    const frame = stack.frames.take(stack.sys_base) orelse return bsd.ENOBUFS;
    @memcpy(frame.buffer[frame.start..][0..data.len], data);
    frame.length = @intCast(data.len);
    const header = frame.push(header_bytes);
    const length: u16 = @intCast(frame.length);
    _ip.put16(header, 0, socket.local_port);
    _ip.put16(header, 2, port);
    _ip.put16(header, 4, length);
    _ip.put16(header, 6, 0);
    var checksum = _ip.finish(_ip.sum(_ip.pseudoSum(source, destination, protocol, length), frame.bytes()));
    // A checksum that comes out 0 is sent as its other form, since 0
    // means none.
    if (checksum == 0) checksum = 0xFFFF;
    _ip.put16(header, 6, checksum);
    stack.counts.udp_sent += 1;
    return _ip.output(stack, frame, source, destination, protocol, hop);
}
