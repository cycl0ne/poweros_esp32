// SPDX-License-Identifier: MIT
//! Routes: where a packet for an address goes - out of which interface,
//! and to which station on it: the address itself when it is on that
//! interface's net, else a gateway. A short list, searched for the
//! longest prefix that holds the address; a default route has a netmask
//! of 0 and holds every address.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const utility = sdk.utility;
const UtilityBase = sdk.interface.utility.UtilityBase;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const Address = @import("../ip6/address.zig").Address;

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

/// The route to `destination` with `netmask` taken away; false if there
/// is none.
pub fn remove(stack: *StackBase, destination: u32, netmask: u32) bool {
    for (&stack.routes) |*route| {
        if (route.used != 0 and route.destination == destination & netmask and route.netmask == netmask) {
            route.* = .{};
            return true;
        }
    }
    return false;
}

/// The default route through `gateway`, in place of any there was; false
/// when no interface is on the gateway's net, or the list is full.
pub fn setDefault(stack: *StackBase, gateway: u32) bool {
    const interface = onNet(stack, gateway) orelse return false;
    _ = remove(stack, 0, 0);
    return add(stack, 0, 0, gateway, interface);
}

/// The interface, not lo0, whose net holds `address`.
pub fn onNet(stack: *StackBase, address: u32) ?*Interface {
    for (&stack.interfaces) |*interface| {
        if (interface.used == 0 or interface.loopback != 0 or interface.address == 0) continue;
        if (interface.holds(address)) return interface;
    }
    return null;
}

/// The default route's gateway, if it goes through `interface`.
pub fn defaultThrough(stack: *StackBase, interface: *Interface) u32 {
    for (&stack.routes) |*route| {
        if (route.used != 0 and route.netmask == 0 and route.interface == interface) return route.gateway;
    }
    return 0;
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

// --- IPv6 routes by hand ------------------------------------------------------------

/// The IPv6 route AddRouteTagList's and DeleteRouteTagList's tags name:
/// the prefix, its length, the router (null when none was given) and the
/// interface (null when none was named).
pub const Wanted6 = struct {
    destination: Address,
    length: u8,
    gateway: ?Address,
    interface: ?*Interface,
};

pub const Tags6 = union(enum) {
    /// No IPv6 tag: the tags are about an IPv4 route.
    none,
    wanted: Wanted6,
    errno: i32,
};

/// What `tags` say of an IPv6 route: `RTA_DefaultGateway6`, or
/// `RTA_Destination6` with `RTA_PrefixLength6` and `RTA_Gateway6`, and
/// `RTA_Interface` with either.
pub fn tags6(stack: *StackBase, ub: *UtilityBase, tags: ?[*]const utility.TagItem) Tags6 {
    const default = ub.FindTagItem(bsd.RTA_DefaultGateway6, tags);
    const destination = ub.FindTagItem(bsd.RTA_Destination6, tags);
    if (default == null and destination == null) return .none;
    var interface: ?*Interface = null;
    if (ub.FindTagItem(bsd.RTA_Interface, tags)) |item| {
        const name: [*:0]const u8 = @ptrFromInt(item.data);
        interface = _netif.named(stack, name) orelse return .{ .errno = bsd.ENXIO };
    }
    var wanted: Wanted6 = .{ .destination = Address.any, .length = 0, .gateway = null, .interface = interface };
    if (default) |item| {
        if (item.data != 0) wanted.gateway = addressAt(item.data);
    } else {
        wanted.destination = addressAt(destination.?.data);
        const length = ub.GetTagData(bsd.RTA_PrefixLength6, 128, tags);
        if (length > 128) return .{ .errno = bsd.EINVAL };
        wanted.length = @intCast(length);
        if (ub.FindTagItem(bsd.RTA_Gateway6, tags)) |item| {
            if (item.data != 0) wanted.gateway = addressAt(item.data);
        }
    }
    if (wanted.gateway) |gateway| {
        if (gateway.isMulticast() or gateway.isUnspecified()) return .{ .errno = bsd.EINVAL };
    }
    return .{ .wanted = wanted };
}

fn addressAt(data: usize) Address {
    const given: *align(1) const bsd.in6_addr = @ptrFromInt(data);
    return .{ .bytes = given.s6_addr };
}
