// SPDX-License-Identifier: MIT
//! Routes: where a packet for an address goes - out of which interface,
//! and to which station on it: the address itself when it is on that
//! interface's net, else a gateway. A short list, searched for the
//! longest prefix that holds the address; a default route has a netmask
//! of 0 and holds every address.

const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;

pub const Route = extern struct {
    destination: u32 = 0,
    netmask: u32 = 0,
    /// The station packets go to, or 0 when the destination is reached
    /// directly on the interface.
    gateway: u32 = 0,
    interface: ?*Interface = null,
    used: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
};

/// Where a packet for an address goes.
pub const Hop = struct {
    interface: *Interface,
    next_hop: u32,
};

/// A route added; false when the list is full.
pub fn add(stack: *StackBase, destination: u32, netmask: u32, gateway: u32, interface: *Interface) bool {
    for (&stack.routes) |*route| {
        if (route.used != 0) continue;
        route.* = .{
            .destination = destination & netmask,
            .netmask = netmask,
            .gateway = gateway,
            .interface = interface,
            .used = 1,
        };
        return true;
    }
    return false;
}

/// Every route through `interface` taken away, when it goes.
pub fn removeAll(stack: *StackBase, interface: *Interface) void {
    for (&stack.routes) |*route| {
        if (route.used != 0 and route.interface == interface) route.* = .{};
    }
}

/// Where a packet for `address` goes, or null if no route holds it. A
/// packet for one of this machine's own addresses goes round through the
/// loopback interface.
pub fn lookup(stack: *StackBase, address: u32) ?Hop {
    if (_netif.owning(stack, address) != null) {
        return .{ .interface = _netif.loopbackOf(stack), .next_hop = address };
    }
    var best: ?*Route = null;
    for (&stack.routes) |*route| {
        if (route.used == 0) continue;
        const interface = route.interface orelse continue;
        if (interface.up == 0) continue;
        if (address & route.netmask != route.destination) continue;
        if (best) |so_far| {
            if (@popCount(route.netmask) <= @popCount(so_far.netmask)) continue;
        }
        best = route;
    }
    const route = best orelse return null;
    return .{
        .interface = route.interface.?,
        .next_hop = if (route.gateway != 0) route.gateway else address,
    };
}
