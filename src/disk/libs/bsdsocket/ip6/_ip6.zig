// SPDX-License-Identifier: MIT
//! IPv6 (RFC 8200): the header and its extension headers read off a
//! packet coming in, the header put on a packet going out, an
//! interface's IPv6 addresses, and what the stack knows of each path's
//! MTU.
//!
//! **In**: the version is 6, the payload inside the packet (a link may
//! pad behind it, which is cut off), the source no multicast address,
//! and the destination this machine's: one of the receiving interface's
//! addresses, one of another interface's that is not link-local, or a
//! group the interface is in - all nodes, and the solicited-node group
//! of each of its addresses. The extension headers are then walked:
//! hop-by-hop options (only first), destination options, a routing
//! header with no segments left, a fragment header - the fragments are
//! put back together (`reassembly.zig`) and the whole goes through here
//! again. An option this machine does not know is dealt with as its two
//! high bits say: skipped, the packet dropped, or dropped with a
//! parameter problem sent back (only for a unicast destination, when the
//! bits say so). A routing header with segments left, a header nothing
//! here speaks, and a hop-by-hop header that is not first are answered
//! with a parameter problem. This machine forwards nothing, so the hop
//! limit is only ever set, never checked.
//!
//! **Out**: a header of 40 bytes, traffic class and flow label 0, and
//! the hop limit its caller gives - the interface's (64 unless a router
//! said otherwise) for a transport, 255 for Neighbor Discovery, 1 for
//! MLD. A packet larger than its path's MTU goes in fragments (RFC 8200,
//! 4.5): each a base header and a fragment header with the packet's
//! identification - random, so no one off the path can guess the next
//! (RFC 7739) - and as many of its bytes as fit, a multiple of 8 but the
//! last. What the base header names goes in the first fragment's
//! fragment header; there is nothing unfragmentable but the base header.
//!
//! **Path MTU** (RFC 8201): a packet-too-big lowers what the stack
//! believes of one destination's path, never below 1280, IPv6's least;
//! the belief is kept for ten minutes, then the link's MTU is tried
//! again. At most `path_mtus_max` destinations are remembered; a new one
//! replaces the oldest.
//!
//! **Addresses**: an interface with IPv6 on holds up to `addresses_max`
//! of them, each with its prefix length and state, and is in the
//! solicited-node group of each (`nd/mld.zig`). The link-local one,
//! `fe80::/64`, is made when the interface is added: its last 64 bits
//! are the interface identifier, as the interface is set to make it -
//! stable (RFC 7217: SHA-256 over the prefix, the link's address, a
//! counter and the stable secret, through crypto.library) or the link's
//! EUI-64. Without crypto.library the EUI-64 is taken. Every address but
//! lo0's `::1` is tentative until Neighbor Discovery has checked that no
//! other station has it (`nd/_nd.zig`).

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const crypto = sdk.crypto;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _ip = @import("../ip/_ip.zig");
const _udp = @import("../udp/_udp.zig");
const _tcp_input = @import("../tcp/input.zig");
const _icmp6 = @import("../icmp6/_icmp6.zig");
const _inet = @import("../inet/_inet.zig");
const _timer = @import("../timer/_timer.zig");
const Timer = _timer.Timer;
const reassembly = @import("reassembly.zig");
const _nd = @import("../nd/_nd.zig");
const mld = @import("../nd/mld.zig");
const router = @import("../nd/router.zig");
const slaac = @import("../nd/slaac.zig");
const _route6 = @import("../route6/_route6.zig");
pub const Address = @import("address.zig").Address;

pub const header_bytes = 40;
/// IPv6's EtherType, the packet type a network device reads it by.
pub const ethertype: u16 = 0x86DD;
pub const default_hop_limit: u8 = 64;
/// The MTU every IPv6 link has at least (RFC 8200, 5).
pub const minimum_mtu: u32 = 1280;

/// The next-header values this layer reads itself.
pub const hop_by_hop: u8 = 0;
pub const routing: u8 = 43;
pub const fragment: u8 = 44;
pub const no_next_header: u8 = 59;
pub const destination_options: u8 = 60;
pub const protocol_icmp6: u8 = 58;

// --- an interface's addresses ------------------------------------------------------

/// The IPv6 addresses one interface holds: its link-local one and one
/// per prefix its routers give.
pub const addresses_max = 4;

pub const AddressState = enum(u8) {
    unused,
    /// Being checked for a duplicate on the link, not used yet.
    tentative,
    preferred,
    /// Still valid, but no longer picked for anything new.
    deprecated,
    /// Another station has it: never used.
    duplicate,
};

pub const InterfaceAddress = extern struct {
    address: Address = .{},
    prefix_length: u8 = 0,
    state: AddressState = .unused,
    /// Made from a router's prefix, rather than the link-local one.
    autoconf: u8 = 0,
    /// Duplicate checks it has yet to send, and how many other
    /// identifiers were tried before it.
    checks_left: u8 = 0,
    counter: u8 = 0,
    pad: u8 = 0,
    /// The nonce its duplicate check carries.
    nonce: [6]u8 = @splat(0),
    /// When it stops being preferred and stops being valid, on the
    /// stack's clock; 0 for never.
    preferred_until: u64 align(4) = 0,
    valid_until: u64 align(4) = 0,
    /// Its next duplicate check, or the end of its lifetime.
    timer: Timer = .{},
    /// The interface it is on.
    interface: ?*Interface = null,

    pub fn usable(entry: *const InterfaceAddress) bool {
        return entry.state == .preferred or entry.state == .deprecated;
    }
};

/// The groups sockets have joined on one interface.
pub const socket_groups_max = 8;

/// A group sockets joined on an interface, and how many of them.
pub const Joined = extern struct {
    address: Address = .{},
    users: u32 = 0,
};

/// An interface's IPv6: whether it is on, how its identifiers are made,
/// its hop limit and addresses.
pub const Link = extern struct {
    enabled: u8 = 0,
    /// IFID_STABLE or IFID_EUI64.
    identifier: u8 = 0,
    hop_limit: u8 = default_hop_limit,
    /// Addresses are made from routers' prefixes (IFIPV6_AUTO).
    autoconf: u8 = 1,
    /// Neighbor Discovery's base reachable time and retransmission
    /// interval, which a router may set.
    reachable_us: u32 = _nd.reachable_us,
    retrans_us: u32 = @intCast(_nd.retrans_us),
    /// What IFID_STABLE hashes with.
    secret: [bsd.IFSECRET_BYTES]u8 = @splat(0),
    addresses: [addresses_max]InterfaceAddress = @splat(.{}),
    /// The groups sockets are in on it (IPV6_JOIN_GROUP).
    groups: [socket_groups_max]Joined = @splat(.{}),
    mld: mld.Mld = .{},
    routers: router.Routers = .{},

    /// The most bytes of IPv6 one packet on the link may have: the
    /// interface's MTU, or less when a router says so.
    pub fn linkMtu(link: *const Link, interface_mtu: u32) u32 {
        return if (link.routers.mtu != 0) @min(link.routers.mtu, interface_mtu) else interface_mtu;
    }
};

/// The address of `interface` that `address` is, in any state.
pub fn addressOf(interface: *Interface, address: Address) ?*InterfaceAddress {
    for (&interface.ip6.addresses) |*entry| {
        if (entry.state != .unused and entry.address.eql(address)) return entry;
    }
    return null;
}

/// `address`/`prefix_length` added to `interface` in `state`, and its
/// solicited-node group joined; null when it holds as many as it can.
/// A tentative address is checked for a duplicate after up to
/// `_nd.dad_delay_us`.
pub fn addAddress(stack: *StackBase, interface: *Interface, address: Address, prefix_length: u8, state: AddressState) ?*InterfaceAddress {
    if (addressOf(interface, address)) |entry| return entry;
    for (&interface.ip6.addresses) |*entry| {
        if (entry.state != .unused) continue;
        entry.* = .{ .address = address, .prefix_length = prefix_length, .state = state, .interface = interface };
        mld.joinGroup(stack, interface, address.solicitedNode());
        if (state == .tentative) _nd.check(stack, entry, _nd.dad_delay_us);
        return entry;
    }
    return null;
}

/// `entry` taken off its interface, its timer and group with it.
pub fn removeAddress(stack: *StackBase, entry: *InterfaceAddress) void {
    _timer.cancel(stack, &entry.timer);
    if (entry.state != .duplicate) mld.leaveGroup(stack, entry.interface.?, entry.address.solicitedNode());
    entry.state = .unused;
}

/// `entry` checked and preferred now: its lifetimes run from here, and
/// once the link-local address is ready the routers are asked.
pub fn ready(stack: *StackBase, entry: *InterfaceAddress, now: u64) void {
    slaac.schedule(stack, entry, now);
    if (entry.address.isLinkLocal()) router.start(stack, entry.interface.?);
}

/// The entry of a group sockets joined on `interface`, if they did.
pub fn socketGroup(interface: *Interface, group: Address) ?*Joined {
    for (&interface.ip6.groups) |*joined| {
        if (joined.users != 0 and joined.address.eql(group)) return joined;
    }
    return null;
}

/// One more socket in `group` on `interface`: the group joined on the
/// device and reported the first time. False when the interface is in as
/// many groups as it can be.
pub fn joinSocketGroup(stack: *StackBase, interface: *Interface, group: Address) bool {
    if (socketGroup(interface, group)) |joined| {
        joined.users += 1;
        return true;
    }
    for (&interface.ip6.groups) |*joined| {
        if (joined.users != 0) continue;
        joined.* = .{ .address = group, .users = 1 };
        mld.joinGroup(stack, interface, group);
        return true;
    }
    return false;
}

/// One socket fewer in `group` on `interface`: the last one leaves it on
/// the device and says so.
pub fn leaveSocketGroup(stack: *StackBase, interface: *Interface, group: Address) void {
    const joined = socketGroup(interface, group) orelse return;
    if (joined.users == 1) mld.leaveGroup(stack, interface, group);
    joined.users -= 1;
}

/// The interface one of whose usable addresses `address` is, if any.
pub fn owner(stack: *StackBase, address: Address) ?*Interface {
    for (&stack.interfaces) |*interface| {
        if (interface.used == 0 or interface.up == 0 or interface.ip6.enabled == 0) continue;
        const entry = addressOf(interface, address) orelse continue;
        if (entry.usable()) return interface;
    }
    return null;
}

/// The interface's link-local address, when it has a usable one.
pub fn linkLocal(interface: *Interface) ?Address {
    for (&interface.ip6.addresses) |*entry| {
        if (entry.usable() and entry.address.isLinkLocal()) return entry.address;
    }
    return null;
}

/// Whether a packet to `address` that came in on `interface` is for this
/// machine.
pub fn isOurs(stack: *StackBase, interface: *Interface, address: Address) bool {
    if (address.isMulticast()) {
        if (address.eql(Address.all_nodes)) return true;
        const scope = address.scope();
        if (scope == 1) return interface.loopback != 0 and address.bytes[15] == 1 and allZero(address.bytes[2..15]);
        for (&interface.ip6.addresses) |*entry| {
            if (entry.state != .unused and entry.state != .duplicate and address.eql(entry.address.solicitedNode())) return true;
        }
        return socketGroup(interface, address) != null;
    }
    if (interface.loopback != 0) return address.eql(Address.loopback) or owner(stack, address) != null;
    const entry = addressOf(interface, address);
    if (entry) |found| return found.usable();
    // A packet for another interface's address, unless the address is
    // link-local and so means only that interface's link.
    return !address.isLinkLocal() and owner(stack, address) != null;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

// --- interface identifiers --------------------------------------------------------

/// The link's EUI-64 (RFC 4291, appendix A): its Ethernet address with
/// `ff:fe` in the middle and the universal bit turned.
pub fn eui64(hardware: [6]u8) [8]u8 {
    return .{ hardware[0] ^ 0x02, hardware[1], hardware[2], 0xff, 0xfe, hardware[3], hardware[4], hardware[5] };
}

/// Whether an interface identifier is one RFC 5453 keeps for itself: all
/// zeros (the subnet-router anycast), the reserved subnet anycasts, and
/// the proxy mobile range.
pub fn isReservedIdentifier(identifier: [8]u8) bool {
    if (allZero(&identifier)) return true;
    const anycast = [7]u8{ 0xfd, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    if (eqlBytes(identifier[0..7], &anycast) and identifier[7] >= 0x80) return true;
    const mobile = [5]u8{ 0x02, 0x00, 0x5e, 0xff, 0xfe };
    return eqlBytes(identifier[0..5], &mobile);
}

fn eqlBytes(a: []const u8, b: []const u8) bool {
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// The stable identifier (RFC 7217) for `prefix` on `interface`: the
/// first 64 bits of SHA-256 over the prefix, the link's address, the
/// counter and the secret. The counter goes up past a reserved result,
/// and past a duplicate found on the link. Null without crypto.library.
pub fn stableIdentifier(stack: *StackBase, interface: *Interface, prefix: *const [8]u8, first_counter: u8) ?[8]u8 {
    const cb = stack.crypto orelse return null;
    var counter = first_counter;
    while (true) : (counter +%= 1) {
        var context: crypto.HashContext = .{};
        if (cb.InitHash(&context, crypto.HASH_SHA256) != 0) return null;
        cb.UpdateHash(&context, prefix, 8);
        cb.UpdateHash(&context, &interface.hardware, 6);
        cb.UpdateHash(&context, &counter, 1);
        cb.UpdateHash(&context, &interface.ip6.secret, bsd.IFSECRET_BYTES);
        var digest: [32]u8 = undefined;
        _ = cb.FinishHash(&context, &digest);
        const identifier = digest[0..8].*;
        if (!isReservedIdentifier(identifier)) return identifier;
    }
}

/// The address `prefix`/64 makes on `interface`, as it is set to make
/// its identifiers; `counter` is how many were found taken before.
pub fn addressFor(stack: *StackBase, interface: *Interface, prefix: *const [8]u8, counter: u8) Address {
    var made: Address = .{};
    made.bytes[0..8].* = prefix.*;
    const identifier = if (interface.ip6.identifier == bsd.IFID_STABLE)
        stableIdentifier(stack, interface, prefix, counter) orelse eui64(interface.hardware)
    else
        eui64(interface.hardware);
    made.bytes[8..16].* = identifier;
    return made;
}

pub const link_local_prefix = [8]u8{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0 };

/// IPv6 on for `interface`, which was just added: all nodes joined, and
/// its link-local address made and checked. Under the lock.
pub fn start(stack: *StackBase, interface: *Interface) void {
    interface.ip6.enabled = 1;
    // Set here, not left to the interface's defaults: on the chip,
    // defaults inside the stack's large base have come out as zeros.
    interface.ip6.hop_limit = default_hop_limit;
    interface.ip6.reachable_us = _nd.reachable_us;
    interface.ip6.retrans_us = @intCast(_nd.retrans_us);
    interface.ip6.routers = .{ .interface = interface };
    if (interface.loopback != 0) {
        _ = addAddress(stack, interface, Address.loopback, 128, .preferred);
        return;
    }
    mld.start(stack, interface);
    const address = addressFor(stack, interface, &link_local_prefix, 0);
    _ = addAddress(stack, interface, address, 64, .tentative);
}

/// IPv6 off for `interface`, which is going: every address, neighbor and
/// report let go.
pub fn stop(stack: *StackBase, interface: *Interface) void {
    for (&interface.ip6.addresses) |*entry| {
        if (entry.state != .unused) removeAddress(stack, entry);
    }
    _nd.forget(stack, interface);
    interface.ip6.groups = @splat(.{});
    @import("../socket/_socket.zig").forgetInterface(stack, interface);
    mld.stop(stack, interface);
    router.stop(stack, interface);
    _route6.removeAll(stack, interface);
    interface.ip6.enabled = 0;
}

// --- the path MTU -------------------------------------------------------------------

pub const path_mtus_max = 8;
/// How long a lowered path MTU is believed.
pub const path_mtu_timeout_us: u64 = 10 * 60 * 1_000_000;

pub const PathMtu = extern struct {
    destination: Address = .{},
    mtu: u32 = 0,
    until: u64 align(4) = 0,
};

pub const PathMtus = extern struct {
    entries: [path_mtus_max]PathMtu = @splat(.{}),
};

/// What a packet to `destination` over a link of `link_mtu` may carry at
/// most, as far as the stack knows.
pub fn pathMtu(stack: *StackBase, destination: Address, link_mtu: u32) u32 {
    const now = _timer.clock(stack);
    for (&stack.path_mtus.entries) |*entry| {
        if (entry.mtu == 0 or !entry.destination.eql(destination)) continue;
        if (entry.until <= now) {
            entry.mtu = 0;
            continue;
        }
        return @min(entry.mtu, link_mtu);
    }
    return link_mtu;
}

/// A packet-too-big from `destination`'s path: its MTU is `mtu`, but
/// never less than IPv6's least. It only ever lowers what is believed.
pub fn learnMtu(stack: *StackBase, destination: Address, reported: u32, now: u64) u32 {
    const mtu = @max(reported, minimum_mtu);
    var slot: *PathMtu = &stack.path_mtus.entries[0];
    for (&stack.path_mtus.entries) |*entry| {
        if (entry.mtu != 0 and entry.destination.eql(destination)) {
            if (entry.until > now and entry.mtu <= mtu) return entry.mtu;
            slot = entry;
            break;
        }
        if (entry.mtu == 0 or entry.until <= now) {
            slot = entry;
        } else if (slot.mtu != 0 and slot.until > now and entry.until < slot.until) {
            slot = entry;
        }
    }
    slot.* = .{ .destination = destination, .mtu = mtu, .until = now + path_mtu_timeout_us };
    return mtu;
}

// --- in ----------------------------------------------------------------------------

/// A packet that came in on `interface`, the frame starting at its IPv6
/// header. The frame is this layer's from here.
pub fn input(stack: *StackBase, interface: *Interface, frame: *Frame) void {
    stack.counts.ip6_received += 1;
    const packet = frame.bytes();
    if (interface.ip6.enabled == 0) return drop(stack, frame, &stack.counts.ip6_not_ours);
    if (packet.len < header_bytes or packet[0] >> 4 != 6) return drop(stack, frame, &stack.counts.ip6_bad_header);
    const payload = _ip.get16(packet, 4);
    if (header_bytes + @as(u32, payload) > packet.len) return drop(stack, frame, &stack.counts.ip6_bad_header);
    frame.trim(header_bytes + @as(u32, payload));
    const source: Address = .{ .bytes = packet[8..24].* };
    const destination: Address = .{ .bytes = packet[24..40].* };
    if (source.isMulticast()) return drop(stack, frame, &stack.counts.ip6_bad_header);
    // ::1 is only ever lo0's.
    if (interface.loopback == 0 and (source.eql(Address.loopback) or destination.eql(Address.loopback))) {
        return drop(stack, frame, &stack.counts.ip6_bad_header);
    }
    if (!isOurs(stack, interface, destination)) return drop(stack, frame, &stack.counts.ip6_not_ours);
    walk(stack, interface, frame, source, destination);
}

fn drop(stack: *StackBase, frame: *Frame, count: *u32) void {
    count.* += 1;
    stack.frames.give(stack.sys_base, frame);
}

/// ICMPv6's parameter-problem codes (RFC 4443, 3.4; RFC 7112).
pub const problem_field: u8 = 0;
pub const problem_next_header: u8 = 1;
pub const problem_option: u8 = 2;
pub const problem_chain: u8 = 3;

/// The extension headers walked, from the one the base header names, and
/// the packet handed to what its last header names.
fn walk(stack: *StackBase, interface: *Interface, frame: *Frame, source: Address, destination: Address) void {
    const packet = frame.bytes();
    var next = packet[6];
    // Where the header that names `next` has that field, and where the
    // header it names starts.
    var named_at: u32 = 6;
    var at: u32 = header_bytes;
    var problem: Problem = .{ .source = source, .destination = destination };
    while (true) {
        switch (next) {
            hop_by_hop, destination_options => {
                if (next == hop_by_hop and at != header_bytes) return problem.send(stack, interface, frame, problem_next_header, named_at);
                const length = extensionLength(packet, at) orelse return drop(stack, frame, &stack.counts.ip6_bad_header);
                switch (options(packet[at..][0..length], destination)) {
                    .go => {},
                    .drop => return drop(stack, frame, &stack.counts.ip6_bad_header),
                    .problem => |offset| return problem.send(stack, interface, frame, problem_option, at + offset),
                }
                named_at = at;
                next = packet[at];
                at += length;
            },
            routing => {
                const length = extensionLength(packet, at) orelse return drop(stack, frame, &stack.counts.ip6_bad_header);
                // Segments left: this machine would have to forward.
                if (packet[at + 3] != 0) return problem.send(stack, interface, frame, problem_field, at + 3);
                named_at = at;
                next = packet[at];
                at += length;
            },
            fragment => {
                if (at + 8 > packet.len) return drop(stack, frame, &stack.counts.ip6_bad_header);
                const word = _ip.get16(packet, at + 2);
                if (word & 0xFFF9 == 0) {
                    // An atomic fragment (RFC 6946): the packet as it is.
                    named_at = at;
                    next = packet[at];
                    at += 8;
                    continue;
                }
                stack.counts.ip6_fragments += 1;
                return reassembly.input(stack, interface, frame, .{
                    .source = source,
                    .destination = destination,
                    .header_length = at,
                    .next_header = packet[at],
                    .word = word,
                    .identification = _ip.get32(packet, at + 4),
                });
            },
            no_next_header => return stack.frames.give(stack.sys_base, frame),
            else => {
                const upper: _inet.Packet = .{ .source = source, .destination = destination, .protocol = next, .header_length = at, .hop_limit = packet[7], .arrived = interface };
                problem.header_length = at;
                problem.protocol = next;
                switch (next) {
                    @as(u8, @intCast(bsd.IPPROTO_UDP)) => {
                        frame.pull(at);
                        _udp.input(stack, interface, frame, upper);
                    },
                    @as(u8, @intCast(bsd.IPPROTO_TCP)) => {
                        frame.pull(at);
                        _tcp_input.input(stack, interface, frame, upper);
                    },
                    protocol_icmp6 => {
                        frame.pull(at);
                        _icmp6.input(stack, interface, frame, upper);
                    },
                    else => {
                        stack.counts.ip6_unknown_protocol += 1;
                        problem.send(stack, interface, frame, problem_next_header, named_at);
                    },
                }
                return;
            },
        }
    }
}

/// A parameter problem to send back about the packet in the frame.
const Problem = struct {
    source: Address,
    destination: Address,
    protocol: u8 = 0,
    header_length: u32 = header_bytes,

    fn send(problem: *const Problem, stack: *StackBase, interface: *Interface, frame: *Frame, code: u8, pointer: u32) void {
        stack.counts.ip6_bad_header += 1;
        const packet: _inet.Packet = .{ .source = problem.source, .destination = problem.destination, .protocol = problem.protocol, .header_length = problem.header_length };
        _icmp6.sendError(stack, interface, frame, packet, _icmp6.parameter_problem, code, pointer);
        stack.frames.give(stack.sys_base, frame);
    }
};

/// The length of the options or routing header at `at`, when all of it
/// is inside the packet.
fn extensionLength(packet: []const u8, at: u32) ?u32 {
    if (at + 8 > packet.len) return null;
    const length = (@as(u32, packet[at + 1]) + 1) * 8;
    if (at + length > packet.len) return null;
    return length;
}

const Verdict = union(enum) { go, drop, problem: u32 };

/// The options of a hop-by-hop or destination-options header: padding
/// and the router alert are known; any other is dealt with as its type's
/// two high bits say (RFC 8200, 4.2).
fn options(header: []const u8, destination: Address) Verdict {
    var at: u32 = 2;
    while (at < header.len) {
        const kind = header[at];
        if (kind == 0) {
            at += 1;
            continue;
        }
        if (at + 2 > header.len) return .drop;
        const length = @as(u32, header[at + 1]) + 2;
        if (at + length > header.len) return .drop;
        switch (kind) {
            1, 5 => {},
            else => switch (kind >> 6) {
                0 => {},
                1 => return .drop,
                2 => return .{ .problem = at },
                else => return if (destination.isMulticast()) .drop else .{ .problem = at },
            },
        }
        at += length;
    }
    return .go;
}

// --- out ----------------------------------------------------------------------------

/// `frame`, holding what `next_header` names, given an IPv6 header and
/// sent on its way by `path` with `hop_limit`. The frame goes with it. 0,
/// or the errno of a packet that could not go.
pub fn output(stack: *StackBase, frame: *Frame, source: Address, destination: Address, next_header: u8, hop_limit: u8, path: _inet.Path) i32 {
    if (frame.length + header_bytes > path.mtu) return fragmentOut(stack, frame, source, destination, next_header, hop_limit, path);
    prepend(stack, frame, source, destination, next_header, hop_limit);
    return _netif.output6(stack, path.interface, frame, path.next_hop);
}

/// The fragment header's bytes.
const fragment_bytes = 8;

/// `frame`'s bytes sent in fragments that each fit the path; the frame
/// goes with it. 0, or the errno of the first fragment that could not go
/// - the rest are not sent then, since the packet cannot be whole.
fn fragmentOut(stack: *StackBase, frame: *Frame, source: Address, destination: Address, next_header: u8, hop_limit: u8, path: _inet.Path) i32 {
    const sys = stack.sys_base;
    defer stack.frames.give(sys, frame);
    const whole = frame.bytes();
    if (whole.len > 65535 - fragment_bytes) return bsd.EMSGSIZE;
    // Room for data in each fragment, in whole 8-byte units.
    const room = (path.mtu - header_bytes - fragment_bytes) & ~@as(u32, 7);
    if (room == 0) return bsd.EMSGSIZE;
    const identification = _nd.random(stack);
    var offset: u32 = 0;
    while (offset < whole.len) {
        const length: u32 = @min(room, @as(u32, @intCast(whole.len)) - offset);
        const more = offset + length < whole.len;
        const piece = stack.frames.take(sys) orelse return bsd.ENOBUFS;
        @memcpy(piece.room()[piece.start..][0..length], whole[offset..][0..length]);
        piece.length = length;
        const header = piece.push(fragment_bytes);
        header[0] = next_header;
        header[1] = 0;
        _ip.put16(header, 2, @intCast(offset | @intFromBool(more)));
        _ip.put32(header, 4, identification);
        prepend(stack, piece, source, destination, fragment, hop_limit);
        stack.counts.ip6_fragments_sent += 1;
        const refused = _netif.output6(stack, path.interface, piece, path.next_hop);
        if (refused != 0) return refused;
        offset += length;
    }
    return 0;
}

/// The IPv6 header put in front of what `frame` holds.
pub fn prepend(stack: *StackBase, frame: *Frame, source: Address, destination: Address, next_header: u8, hop_limit: u8) void {
    const payload = frame.length;
    const header = frame.push(header_bytes);
    _ip.put32(header, 0, 0x6000_0000);
    _ip.put16(header, 4, @intCast(payload));
    header[6] = next_header;
    header[7] = hop_limit;
    header[8..24].* = source.bytes;
    header[24..40].* = destination.bytes;
    stack.counts.ip6_sent += 1;
}
