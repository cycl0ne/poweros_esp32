// SPDX-License-Identifier: MIT
//! Routers, as a host sees them (RFC 4861, 6.3 and 8): solicited when the
//! link-local address is ready, and what their advertisements and
//! redirects say taken in.
//!
//! **Solicitation**: once the link-local address is preferred, after a
//! random delay of up to a second, a router solicitation goes to all
//! routers, and again every four seconds, three in all, until an
//! advertisement comes.
//!
//! **An advertisement** is taken only from a link-local address (and, as
//! every ND message, with a hop limit of 255 and code 0). What it sets:
//! the interface's hop limit, reachable time and retransmission interval
//! where it names them; a default route through the router for its
//! lifetime, or none when that is 0; the router's Ethernet address in
//! the neighbor cache; the link's MTU, when it is no larger than the
//! interface takes and no less than 1280; for each prefix, an on-link
//! route for its valid lifetime when its L flag is set, and an address
//! made from it when its A flag is (`slaac.zig`); the name servers of an
//! RDNSS option (RFC 8106) for their lifetime; and its M and O flags,
//! kept for NetStatus. A prefix that is link-local is passed over.
//!
//! **A redirect** is taken only from the router that is the current next
//! hop for its destination; its target is link-local, or the destination
//! itself when that is on the link. It makes a route to the one
//! destination, for ten minutes: a redirect carries no lifetime, and one
//! that stays forever would fill the route list.

const sdk = @import("sdk");
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _timer = @import("../timer/_timer.zig");
const Timer = _timer.Timer;
const _ip = @import("../ip/_ip.zig");
const _ip6 = @import("../ip6/_ip6.zig");
const _inet = @import("../inet/_inet.zig");
const _route6 = @import("../route6/_route6.zig");
const _nd = @import("_nd.zig");
const slaac = @import("slaac.zig");
const Address = @import("../ip6/address.zig").Address;

pub const solicitations_max = 3;
pub const solicitation_interval_us: u64 = 4_000_000;
pub const solicitation_delay_us: u32 = 1_000_000;
pub const redirect_life_us: u64 = 10 * 60 * 1_000_000;

pub const option_prefix: u8 = 3;
pub const option_mtu: u8 = 5;
pub const option_rdnss: u8 = 25;

pub const flag_managed: u8 = 0x80;
pub const flag_other: u8 = 0x40;
pub const prefix_on_link: u8 = 0x80;
pub const prefix_autonomous: u8 = 0x40;

/// The name servers routers named for one interface.
pub const servers_max = 3;

/// An interface's routers: its solicitations, what the advertisements
/// said of the network, and the name servers they named.
pub const Routers = extern struct {
    timer: Timer = .{},
    solicitations_left: u8 = 0,
    /// The last advertisement's M and O flags.
    flags: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },
    /// The link's MTU a router gave, or 0.
    mtu: u32 = 0,
    servers: [servers_max]Address = @splat(.{}),
    servers_until: [servers_max]u64 align(4) = @splat(0),
    interface: ?*Interface = null,
};

/// Routers solicited on `interface`, whose link-local address is ready.
pub fn start(stack: *StackBase, interface: *Interface) void {
    const routers = &interface.ip6.routers;
    routers.interface = interface;
    routers.timer.fire = &fire;
    routers.solicitations_left = solicitations_max;
    _ = _timer.set(stack, &routers.timer, _timer.clock(stack) + _nd.below(stack, solicitation_delay_us));
}

pub fn stop(stack: *StackBase, interface: *Interface) void {
    _timer.cancel(stack, &interface.ip6.routers.timer);
    interface.ip6.routers = .{};
}

fn fire(stack: *StackBase, fired: *Timer, now: u64) void {
    const routers: *Routers = @fieldParentPtr("timer", fired);
    const interface = routers.interface.?;
    if (routers.solicitations_left == 0) return;
    routers.solicitations_left -= 1;
    solicit(stack, interface);
    if (routers.solicitations_left > 0) _ = _timer.set(stack, &routers.timer, now + solicitation_interval_us);
}

/// A router solicitation to all routers, with our Ethernet address.
fn solicit(stack: *StackBase, interface: *Interface) void {
    const source = _ip6.linkLocal(interface) orelse return;
    const frame = stack.frames.take(stack.sys_base) orelse return;
    const bytes = frame.room()[frame.start..][0..8];
    frame.length = 8;
    bytes.* = .{ _nd.router_solicitation, 0, 0, 0, 0, 0, 0, 0 };
    _nd.addLinkOption(frame, _nd.option_source, interface.hardware);
    stack.counts.nd_solicits_sent += 1;
    _nd.send(stack, interface, frame, source, Address.all_routers, null);
}

/// A lifetime in seconds as a time on the stack's clock: 0 for
/// infinity (all ones).
pub fn until(now: u64, seconds: u32) u64 {
    if (seconds == 0xFFFF_FFFF) return 0;
    return now + @as(u64, seconds) * 1_000_000;
}

fn lifetimeUs(seconds: u32) u64 {
    if (seconds == 0xFFFF_FFFF) return 0;
    return @as(u64, seconds) * 1_000_000;
}

/// Each option of an ND message behind `at`: its type and all of it;
/// null at the end, or when one is malformed (`bad` is set then).
const Options = struct {
    bytes: []const u8,
    at: usize,
    bad: bool = false,

    fn next(options: *Options) ?[]const u8 {
        if (options.at >= options.bytes.len) return null;
        if (options.at + 2 > options.bytes.len) {
            options.bad = true;
            return null;
        }
        const length = @as(usize, options.bytes[options.at + 1]) * 8;
        if (length == 0 or options.at + length > options.bytes.len) {
            options.bad = true;
            return null;
        }
        const option = options.bytes[options.at..][0..length];
        options.at += length;
        return option;
    }
};

/// Whether every option is well formed, before anything is taken from
/// them.
fn wellFormed(bytes: []const u8, at: usize) bool {
    var options: Options = .{ .bytes = bytes, .at = at };
    while (options.next()) |_| {}
    return !options.bad;
}

/// A router advertisement that came in on `interface`, checked for hop
/// limit and code.
pub fn advertised(stack: *StackBase, interface: *Interface, bytes: []const u8, packet: _inet.Packet, now: u64) void {
    if (bytes.len < 16 or !packet.source.isLinkLocal() or !wellFormed(bytes, 16)) {
        stack.counts.nd_bad += 1;
        return;
    }
    const routers = &interface.ip6.routers;
    routers.solicitations_left = 0;
    _timer.cancel(stack, &routers.timer);
    routers.flags = bytes[5] & (flag_managed | flag_other);
    if (bytes[4] != 0) interface.ip6.hop_limit = bytes[4];
    const reachable_ms = _ip.get32(bytes, 8);
    if (reachable_ms != 0 and reachable_ms <= 3_600_000) interface.ip6.reachable_us = reachable_ms * 1000;
    const retrans_ms = _ip.get32(bytes, 12);
    if (retrans_ms != 0 and retrans_ms <= 3_600_000) interface.ip6.retrans_us = retrans_ms * 1000;
    const lifetime_s = _ip.get16(bytes, 6);
    if (lifetime_s != 0) {
        _ = _route6.set(stack, interface, Address.any, 0, packet.source, .advertised, @as(u64, lifetime_s) * 1_000_000);
    } else {
        _ = _route6.remove(stack, interface, Address.any, 0, packet.source);
    }

    var options: Options = .{ .bytes = bytes, .at = 16 };
    while (options.next()) |option| {
        switch (option[0]) {
            _nd.option_source => if (option.len >= 8) _nd.heard(stack, interface, packet.source, option[2..8].*, now),
            option_mtu => if (option.len == 8) {
                const mtu = _ip.get32(option, 4);
                if (mtu >= _ip6.minimum_mtu and mtu <= interface.mtu) routers.mtu = mtu;
            },
            option_prefix => if (option.len == 32) prefix(stack, interface, option, now),
            option_rdnss => if (option.len >= 24 and (option.len - 8) % 16 == 0) servers(routers, option, now),
            else => {},
        }
    }
    if (_nd.find(stack, interface, packet.source)) |entry| entry.router = 1;
}

fn prefix(stack: *StackBase, interface: *Interface, option: []const u8, now: u64) void {
    const length = option[2];
    const flags = option[3];
    const valid_s = _ip.get32(option, 4);
    const preferred_s = _ip.get32(option, 8);
    const address: Address = .{ .bytes = option[16..32].* };
    if (address.isLinkLocal() or address.isMulticast() or length > 128) return;
    if (flags & prefix_on_link != 0) {
        if (valid_s == 0) {
            _ = _route6.remove(stack, interface, address, length, Address.any);
        } else {
            _ = _route6.set(stack, interface, address, length, Address.any, .advertised, lifetimeUs(valid_s));
        }
    }
    if (flags & prefix_autonomous != 0) slaac.prefix(stack, interface, address, length, valid_s, preferred_s, now);
}

fn servers(routers: *Routers, option: []const u8, now: u64) void {
    const lifetime_s = _ip.get32(option, 4);
    var at: usize = 8;
    while (at + 16 <= option.len) : (at += 16) {
        const server: Address = .{ .bytes = option[at..][0..16].* };
        const slot = for (&routers.servers, 0..) |*held, index| {
            if (held.eql(server)) break index;
        } else for (&routers.servers, routers.servers_until, 0..) |*held, held_until, index| {
            if (held.isUnspecified() or (held_until != 0 and held_until <= now)) break index;
        } else continue;
        if (lifetime_s == 0) {
            routers.servers[slot] = .{};
            routers.servers_until[slot] = 0;
        } else {
            routers.servers[slot] = server;
            routers.servers_until[slot] = until(now, lifetime_s);
        }
    }
}

/// The name servers routers named on `interface` that are still valid,
/// into `into`; how many there are.
pub fn nameServers(interface: *Interface, now: u64, into: []Address) usize {
    const routers = &interface.ip6.routers;
    var count: usize = 0;
    for (routers.servers, routers.servers_until) |server, held_until| {
        if (server.isUnspecified() or (held_until != 0 and held_until <= now) or count == into.len) continue;
        into[count] = server;
        count += 1;
    }
    return count;
}

/// A redirect that came in on `interface`, checked for hop limit and
/// code.
pub fn redirected(stack: *StackBase, interface: *Interface, bytes: []const u8, packet: _inet.Packet, now: u64) void {
    if (bytes.len < 40 or !packet.source.isLinkLocal() or !wellFormed(bytes, 40)) {
        stack.counts.nd_bad += 1;
        return;
    }
    const target: Address = .{ .bytes = bytes[8..24].* };
    const destination: Address = .{ .bytes = bytes[24..40].* };
    const on_link = target.eql(destination);
    if (destination.isMulticast() or (!on_link and !target.isLinkLocal())) {
        stack.counts.nd_bad += 1;
        return;
    }
    const hop = _route6.lookup(stack, destination) orelse return;
    if (hop.interface != interface or !hop.next_hop.eql(packet.source)) return;
    _ = _route6.set(stack, interface, destination, 128, if (on_link) Address.any else target, .redirect, redirect_life_us);
    var options: Options = .{ .bytes = bytes, .at = 40 };
    while (options.next()) |option| {
        if (option[0] == _nd.option_target and option.len >= 8) _nd.heard(stack, interface, target, option[2..8].*, now);
    }
}
