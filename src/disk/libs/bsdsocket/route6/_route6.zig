// SPDX-License-Identifier: MIT
//! IPv6 routes: where a packet for an IPv6 address goes, beside IPv4's
//! `route/`. A short list of prefixes, each on an interface, either on
//! the link (the address itself is the next hop) or through a router on
//! it; the longest prefix that holds the address wins. The default
//! routes are the ones of length 0.
//!
//! **Where they come from**: router advertisements (`nd/router.zig`) add
//! an on-link route per prefix with the L flag and a default route per
//! router that says it is one, each for the lifetime the router gave;
//! a redirect adds a route for one destination; and a program adds them
//! by hand. A route whose lifetime is over is not used and its slot is
//! free again, so nothing needs a timer.
//!
//! **Among default routers** (RFC 4861, 6.3.6) one whose Ethernet
//! address the neighbor cache holds is taken first, then one not asked
//! about yet, and last one whose solicitation is still unanswered - so a
//! router that stops answering is left while it is being asked.

const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _timer = @import("../timer/_timer.zig");
const _nd = @import("../nd/_nd.zig");
const Address = @import("../ip6/address.zig").Address;

pub const routes_max = 16;

pub const Origin = enum(u8) { free, manual, advertised, redirect };

pub const Route = extern struct {
    destination: Address = .{},
    /// The router packets go through, or `::` for a prefix on the link.
    gateway: Address = .{},
    interface: ?*Interface = null,
    /// When it stops being used, on the stack's clock; 0 for never.
    until: u64 align(4) = 0,
    prefix_length: u8 = 0,
    origin: Origin = .free,
    pad: [2]u8 = .{ 0, 0 },

    pub fn live(route: *const Route, now: u64) bool {
        return route.origin != .free and (route.until == 0 or route.until > now);
    }
};

pub const Table = extern struct {
    routes: [routes_max]Route = @splat(.{}),
};

/// Where a packet for an IPv6 address goes.
pub const Hop = struct {
    interface: *Interface,
    next_hop: Address,
};

fn masked(address: Address, length: u8) Address {
    var made = address;
    for (&made.bytes, 0..) |*byte, index| {
        const bits: i32 = @as(i32, length) - @as(i32, @intCast(index * 8));
        if (bits >= 8) continue;
        byte.* = if (bits <= 0) 0 else byte.* & ~(@as(u8, 0xFF) >> @intCast(bits));
    }
    return made;
}

/// The live route to exactly `destination`/`length` through `gateway`
/// on `interface`, if there is one.
pub fn find(stack: *StackBase, interface: *Interface, destination: Address, length: u8, gateway: Address) ?*Route {
    const now = _timer.clock(stack);
    const wanted = masked(destination, length);
    for (&stack.routes6.routes) |*route| {
        if (!route.live(now) or route.interface != interface or route.prefix_length != length) continue;
        if (route.destination.eql(wanted) and route.gateway.eql(gateway)) return route;
    }
    return null;
}

/// A route added, or the one there was brought up to date: `lifetime_us`
/// from now (0 for never). False when the list is full.
pub fn set(stack: *StackBase, interface: *Interface, destination: Address, length: u8, gateway: Address, origin: Origin, lifetime_us: u64) bool {
    const now = _timer.clock(stack);
    const until: u64 = if (lifetime_us == 0) 0 else now + lifetime_us;
    if (find(stack, interface, destination, length, gateway)) |route| {
        route.until = until;
        route.origin = origin;
        return true;
    }
    for (&stack.routes6.routes) |*route| {
        if (route.live(now)) continue;
        route.* = .{
            .destination = masked(destination, length),
            .gateway = gateway,
            .interface = interface,
            .until = until,
            .prefix_length = length,
            .origin = origin,
        };
        return true;
    }
    return false;
}

/// The route to `destination`/`length` through `gateway` on `interface`
/// taken away; false if there is none.
pub fn remove(stack: *StackBase, interface: *Interface, destination: Address, length: u8, gateway: Address) bool {
    const route = find(stack, interface, destination, length, gateway) orelse return false;
    route.origin = .free;
    return true;
}

/// Every live route to `destination`/`length` taken away - only those
/// through `gateway` and on `interface` when they are given: how many.
pub fn removeMatching(stack: *StackBase, interface: ?*Interface, destination: Address, length: u8, gateway: ?Address) u32 {
    const now = _timer.clock(stack);
    const wanted = masked(destination, length);
    var removed: u32 = 0;
    for (&stack.routes6.routes) |*route| {
        if (!route.live(now) or route.prefix_length != length or !route.destination.eql(wanted)) continue;
        if (interface) |only| if (route.interface != only) continue;
        if (gateway) |through| if (!route.gateway.eql(through)) continue;
        route.origin = .free;
        removed += 1;
    }
    return removed;
}

/// Every route on `interface` gone, when the interface goes.
pub fn removeAll(stack: *StackBase, interface: *Interface) void {
    for (&stack.routes6.routes) |*route| {
        if (route.interface == interface) route.origin = .free;
    }
}

/// Where a packet for `destination` goes, or null when no route holds it.
pub fn lookup(stack: *StackBase, destination: Address) ?Hop {
    const now = _timer.clock(stack);
    var best: ?*Route = null;
    var best_score: u32 = 0;
    for (&stack.routes6.routes) |*route| {
        if (!route.live(now)) continue;
        const interface = route.interface.?;
        if (interface.up == 0 or interface.ip6.enabled == 0) continue;
        if (!destination.inPrefix(route.destination, route.prefix_length)) continue;
        // Longer prefixes first; among default routers, known ones first.
        var score: u32 = (@as(u32, route.prefix_length) + 1) * 4;
        if (!route.gateway.isUnspecified()) {
            if (_nd.find(stack, interface, route.gateway)) |neighbor| {
                if (neighbor.state != .incomplete) score += 2;
            } else score += 1;
        }
        if (best == null or score > best_score) {
            best = route;
            best_score = score;
        }
    }
    const route = best orelse return null;
    const next_hop = if (route.gateway.isUnspecified()) destination else route.gateway;
    return .{ .interface = route.interface.?, .next_hop = next_hop };
}

/// Whether a route on `interface` goes through `address`.
pub fn isRouter(stack: *StackBase, interface: *Interface, address: Address) bool {
    const now = _timer.clock(stack);
    for (&stack.routes6.routes) |*route| {
        if (route.live(now) and route.interface == interface and route.gateway.eql(address)) return true;
    }
    return false;
}
