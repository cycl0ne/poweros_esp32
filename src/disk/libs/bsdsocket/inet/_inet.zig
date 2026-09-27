// SPDX-License-Identifier: MIT
//! What the transports see of the IP layers, whichever family carries a
//! packet: its two addresses (`ip6/address.zig`, an IPv4 one mapped), a
//! route to a destination, sending, the pseudo header their checksums sum
//! over, and the error that goes back when a packet has nowhere to go. Each
//! call looks at the address and hands over to IPv4's layer (`ip/`,
//! `route/`, `icmp/`) or IPv6's (`ip6/`, `icmp6/`).
//!
//! A transport never needs to know which family it is on: TCP, UDP and a
//! datagram's sender take an `Address` and a `Path`, and the family comes
//! from the address.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _route = @import("../route/_route.zig");
const _ip = @import("../ip/_ip.zig");
const _icmp = @import("../icmp/_icmp.zig");
const _ip6 = @import("../ip6/_ip6.zig");
const _icmp6 = @import("../icmp6/_icmp6.zig");
const _route6 = @import("../route6/_route6.zig");
const Address = @import("../ip6/address.zig").Address;

/// A packet as it reaches a transport: who sent it and to whom, what it
/// carries, and how many bytes of IP header - extension headers included -
/// stand in front of the transport's header in the frame.
pub const Packet = struct {
    source: Address,
    destination: Address,
    protocol: u8,
    header_length: u32,
    /// The hop limit it came with, for IPv6: Neighbor Discovery takes
    /// only what no router forwarded (255).
    hop_limit: u8 = 0,
    /// The interface it came in on, for an IPv6 packet: the scope of a
    /// link-local sender.
    arrived: ?*Interface = null,

    /// The IPv4 packet it came as, for IPv4's own layer.
    pub fn fromV4(header: _ip.Header) Packet {
        return .{
            .source = Address.fromV4(header.source),
            .destination = Address.fromV4(header.destination),
            .protocol = header.protocol,
            .header_length = header.header_length,
        };
    }

    fn v4Header(packet: Packet) _ip.Header {
        return .{
            .source = packet.source.v4(),
            .destination = packet.destination.v4(),
            .protocol = packet.protocol,
            .header_length = packet.header_length,
            .identification = 0,
        };
    }
};

/// Where a packet for a destination goes: out of which interface, to
/// which station on it, and how many bytes of IP one packet on the way
/// may have.
pub const Path = struct {
    interface: *Interface,
    next_hop: Address,
    mtu: u32,
};

/// The path to `destination`, or null when nothing routes it. `scope` is
/// the interface an IPv6 link-local or link-scope destination is on - the
/// one a packet from it came in on - and without it the first interface
/// that speaks IPv6 is taken. Any other IPv6 destination goes by the
/// IPv6 routes (`route6/`).
pub fn route(stack: *StackBase, destination: Address, scope: ?*Interface) ?Path {
    if (destination.isV4()) {
        const hop = _route.lookup(stack, destination.v4()) orelse return null;
        return .{ .interface = hop.interface, .next_hop = Address.fromV4(hop.next_hop), .mtu = hop.interface.mtu };
    }
    // To this machine itself: over lo0.
    if (destination.eql(Address.loopback) or (destination.isMulticast() and destination.scope() == 1) or
        (!destination.isMulticast() and _ip6.owner(stack, destination) != null))
    {
        const lo = _netif.loopbackOf(stack);
        return .{ .interface = lo, .next_hop = destination, .mtu = lo.mtu };
    }
    // A link-local address, and a group of any scope beyond the
    // interface: sent on the link itself, never through a router.
    if (destination.isLinkLocal() or destination.isMulticast()) {
        const interface = scope orelse firstLink(stack) orelse return null;
        if (interface.ip6.enabled == 0 or interface.up == 0) return null;
        return pathOn(stack, interface, destination, destination);
    }
    const hop = _route6.lookup(stack, destination) orelse return null;
    return pathOn(stack, hop.interface, hop.next_hop, destination);
}

fn speaks6(interface: *const Interface) bool {
    return interface.used != 0 and interface.up != 0 and interface.ip6.enabled != 0;
}

/// The first interface on a link that speaks IPv6.
fn firstLink(stack: *StackBase) ?*Interface {
    for (&stack.interfaces) |*interface| {
        if (speaks6(interface) and interface.loopback == 0) return interface;
    }
    return null;
}

fn pathOn(stack: *StackBase, interface: *Interface, next_hop: Address, destination: Address) Path {
    return .{ .interface = interface, .next_hop = next_hop, .mtu = _ip6.pathMtu(stack, destination, interface.ip6.linkMtu(interface.mtu)) };
}

/// The address a packet to `destination` over `path` goes from, when its
/// socket is bound to none; for IPv6 the one RFC 6724 would pick among
/// the interface's: of the destination's scope, preferred before
/// deprecated, then the one sharing the most leading bits with it.
pub fn sourceFor(path: Path, destination: Address) ?Address {
    if (destination.isV4()) {
        return Address.fromV4(if (path.interface.loopback != 0) bsd.INADDR_LOOPBACK else path.interface.address);
    }
    if (path.interface.loopback != 0) return if (destination.isMulticast()) Address.loopback else destination;
    const link_scope = destination.scope() <= 2;
    var best: ?Address = null;
    var best_score: u32 = 0;
    for (&path.interface.ip6.addresses) |*entry| {
        if (!entry.usable()) continue;
        if (entry.address.isLinkLocal() != link_scope) continue;
        const score: u32 = @as(u32, if (entry.state == .preferred) 256 else 0) + entry.address.commonBits(destination) + 1;
        if (score > best_score) {
            best = entry.address;
            best_score = score;
        }
    }
    return best;
}

/// The IP header's bytes in front of what a transport sends to
/// `destination`.
pub fn headerBytes(destination: Address) u32 {
    return if (destination.isV4()) _ip.header_bytes else 40;
}

/// Whether `destination` is one every station on its net answers to:
/// IPv4's limited broadcast, or the path's interface's. IPv6 has none.
pub fn isBroadcast(destination: Address, path: Path) bool {
    if (!destination.isV4()) return false;
    const address = destination.v4();
    return address == bsd.INADDR_BROADCAST or address == path.interface.broadcast;
}

/// `frame`, holding a transport's header and data, sent from `source` to
/// `destination` over `path`, with `hop_limit` for IPv6 (0: the
/// interface's, or 1 for a group). The frame goes with it. 0, or the
/// errno of a packet that could not go.
pub fn output(stack: *StackBase, frame: *Frame, source: Address, destination: Address, protocol: u8, path: Path, hop_limit: u8) i32 {
    if (source.isV4() != destination.isV4()) {
        stack.frames.give(stack.sys_base, frame);
        return bsd.ENETUNREACH;
    }
    if (destination.isV4()) {
        return _ip.output(stack, frame, source.v4(), destination.v4(), protocol, .{ .interface = path.interface, .next_hop = path.next_hop.v4() });
    }
    // A group hears a packet on its own link only, unless asked.
    const hops: u8 = if (hop_limit != 0) hop_limit else if (destination.isMulticast()) 1 else path.interface.ip6.hop_limit;
    return _ip6.output(stack, frame, source, destination, protocol, hops, path);
}

/// The sum TCP and UDP start their checksum with: both addresses, the
/// protocol and the transport's length, as each family's pseudo header
/// lays them out (RFC 768 for IPv4, RFC 8200 8.1 for IPv6). The words sum
/// the same whichever order they come in, so the two differ only in what
/// they hold.
pub fn pseudoSum(source: Address, destination: Address, protocol: u8, length: u32) u32 {
    if (source.isV4()) return _ip.pseudoSum(source.v4(), destination.v4(), protocol, length);
    var total = _ip.sum(0, &source.bytes);
    total = _ip.sum(total, &destination.bytes);
    return total + (length >> 16) + (length & 0xFFFF) + protocol;
}

/// Why a packet has nowhere to go, which the error that answers it says.
pub const Unreachable = enum { port };

/// The error that tells a packet's sender it went nowhere: ICMP's
/// destination-unreachable or ICMPv6's. `frame` came in on `interface`,
/// starts at the packet's IP header and stays the caller's.
pub fn sendUnreachable(stack: *StackBase, interface: *Interface, frame: *Frame, packet: Packet, why: Unreachable) void {
    if (packet.source.isV4()) {
        return _icmp.sendUnreachable(stack, frame, packet.v4Header(), switch (why) {
            .port => _icmp.code_port,
        });
    }
    _icmp6.sendError(stack, interface, frame, packet, _icmp6.destination_unreachable, switch (why) {
        .port => _icmp6.code_port,
    }, 0);
}
