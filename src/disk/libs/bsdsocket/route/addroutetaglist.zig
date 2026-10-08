// SPDX-License-Identifier: MIT
//! AddRouteTagList: a route to a net, or the default route, IPv4 or
//! IPv6.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const utility = sdk.utility;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("../socket/_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _route = @import("_route.zig");
const _route6 = @import("../route6/_route6.zig");
const _inet = @import("../inet/_inet.zig");
const _netif = @import("../netif/_netif.zig");
const Address = @import("../ip6/address.zig").Address;

/// A route added: to a net or a host through a gateway, or the default
/// route; IPv4 or IPv6.
///
/// SYNOPSIS:
/// ```zig
/// fn AddRouteTagList(base: *SocketBase, tags: ?[*]const TagItem) i32
/// ```
///
/// SINCE: 1.0. LVO -148.
///
/// INPUTS:
/// - `tags` - IPv4: `RTA_DefaultGateway` alone; or `RTA_Destination`,
///   `RTA_NetMask` (a host unless given) and `RTA_Gateway`, addresses in
///   network order. IPv6: `RTA_DefaultGateway6`; or `RTA_Destination6`,
///   `RTA_PrefixLength6` (128 unless given) and `RTA_Gateway6` (none for
///   a prefix on the link); and `RTA_Interface` with either - each address
///   a pointer to an `in6_addr`.
///
/// RESULT:
/// 0, or -1 with Errno(): `EINVAL` (no destination or no gateway, a
/// prefix longer than 128, a group as the gateway, an interface that does
/// not speak IPv6, or an IPv6 prefix on the link without its interface),
/// `ENETUNREACH` (the gateway is on no interface's net or link), `ENXIO`
/// (no interface of that name), `ENOBUFS` (the route list is full).
///
/// BEHAVIOR:
/// A route goes out of the interface whose net holds its gateway. A
/// default route replaces the one there was. Of the routes that hold an
/// address, the one with the longest netmask is taken.
///
/// An IPv6 route goes out of `RTA_Interface`, or of the interface its
/// router is on the link of - for a link-local router the first interface
/// that speaks IPv6. It stays until DeleteRouteTagList or until its
/// interface goes; a default route is one more beside those routers
/// advertise, and is taken as they are (`NETSTATUS_ROUTES6` shows them
/// all).
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The tags are read and not kept.
///
/// NOTES:
/// The routes to an interface's own net come and go with it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DeleteRouteTagList`, `AddInterfaceTagList`
///
/// EXAMPLES:
/// ```zig
/// const tags = [_]TagItem{ .{ .tag = bsd.RTA_DefaultGateway, .data = sb.Inet_Addr("10.0.2.2") }, .{} };
/// _ = sb.AddRouteTagList(&tags);
///
/// var router: bsd.in6_addr = .{};
/// _ = sb.Inet_PtoN(bsd.AF_INET6, "fe80::1", &router);
/// const tags6 = [_]TagItem{
///     .{ .tag = bsd.RTA_DefaultGateway6, .data = @intFromPtr(&router) },
///     .{ .tag = bsd.RTA_Interface, .data = @intFromPtr("eth0") },
///     .{},
/// };
/// _ = sb.AddRouteTagList(&tags6);
/// ```
pub fn AddRouteTagList(sb: *SocketBase, tags: ?[*]const utility.TagItem) i32 {
    const stack = sb.stack;
    const ub = stack.utility.?;
    const held = _lock.take(stack);
    defer _lock.give(stack, held);
    switch (_route.tags6(stack, ub, tags)) {
        .none => {},
        .errno => |errno| return _socket.fail(sb, errno, "AddRouteTagList"),
        .wanted => |wanted| {
            const errno = add6(stack, wanted);
            if (errno != 0) return _socket.fail(sb, errno, "AddRouteTagList");
            return 0;
        },
    }
    if (ub.FindTagItem(bsd.RTA_DefaultGateway, tags)) |item| {
        if (!_route.setDefault(stack, bsd.ntohl(@truncate(item.data)))) return _socket.fail(sb, bsd.ENETUNREACH, "AddRouteTagList");
        return 0;
    }
    const destination_item = ub.FindTagItem(bsd.RTA_Destination, tags) orelse return _socket.fail(sb, bsd.EINVAL, "AddRouteTagList");
    const gateway_item = ub.FindTagItem(bsd.RTA_Gateway, tags) orelse return _socket.fail(sb, bsd.EINVAL, "AddRouteTagList");
    const gateway = bsd.ntohl(@truncate(gateway_item.data));
    const netmask = bsd.ntohl(@truncate(ub.GetTagData(bsd.RTA_NetMask, 0xFFFF_FFFF, tags)));
    const interface = _route.onNet(stack, gateway) orelse return _socket.fail(sb, bsd.ENETUNREACH, "AddRouteTagList");
    if (!_route.add(stack, bsd.ntohl(@truncate(destination_item.data)), netmask, gateway, interface)) return _socket.fail(sb, bsd.ENOBUFS, "AddRouteTagList");
    return 0;
}

/// The IPv6 route `wanted` added: 0, or the errno.
fn add6(stack: *_base.StackBase, wanted: _route.Wanted6) i32 {
    const interface = wanted.interface orelse blk: {
        // A router's interface is the one it is on the link of; a prefix
        // on the link has to be told its.
        const gateway = wanted.gateway orelse return bsd.EINVAL;
        const path = _inet.route(stack, gateway, null) orelse return bsd.ENETUNREACH;
        if (!path.next_hop.eql(gateway)) return bsd.ENETUNREACH;
        break :blk path.interface;
    };
    if (interface.loopback != 0 or interface.ip6.enabled == 0) return bsd.EINVAL;
    if (wanted.length == 0 and wanted.gateway == null) return bsd.EINVAL;
    if (!_route6.set(stack, interface, wanted.destination, wanted.length, wanted.gateway orelse Address.any, .manual, 0)) return bsd.ENOBUFS;
    return 0;
}
