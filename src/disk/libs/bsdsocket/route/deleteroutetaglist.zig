// SPDX-License-Identifier: MIT
//! DeleteRouteTagList: a route taken away.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const utility = sdk.utility;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("../socket/_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _route = @import("_route.zig");
const _route6 = @import("../route6/_route6.zig");

/// A route taken away: the one to a net or host, or the default route;
/// IPv4 or IPv6.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteRouteTagList(base: *SocketBase, tags: ?[*]const TagItem) i32
/// ```
///
/// SINCE: 1.0. LVO -152.
///
/// INPUTS:
/// - `tags` - IPv4: `RTA_Destination` and `RTA_NetMask` (a host unless
///   given); or `RTA_DefaultGateway`, with any value, for the default
///   route. IPv6: `RTA_Destination6` and `RTA_PrefixLength6` (128 unless
///   given), with `RTA_Gateway6` and `RTA_Interface` if only the route
///   through that router or on that interface is meant; or
///   `RTA_DefaultGateway6`, a router's address for the default route
///   through it, 0 for every default route.
///
/// RESULT:
/// 0, or -1 with Errno(): `EINVAL` (no destination, a prefix longer than
/// 128), `ENXIO` (there is no such route, or no interface of that name).
///
/// BEHAVIOR:
/// The route is found by its destination and netmask, as it was added.
/// IPv6 routes are found by their prefix - and router and interface when
/// they are given - and every one that fits goes, whether it was added
/// by hand or a router advertised it; an advertised one comes back with
/// the router's next advertisement.
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
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddRouteTagList`
///
/// EXAMPLES:
/// ```zig
/// const tags = [_]TagItem{ .{ .tag = bsd.RTA_DefaultGateway, .data = 0 }, .{} };
/// _ = sb.DeleteRouteTagList(&tags);
/// ```
pub fn DeleteRouteTagList(sb: *SocketBase, tags: ?[*]const utility.TagItem) i32 {
    const stack = sb.stack;
    const ub = stack.utility.?;
    const held = _lock.take(stack);
    defer _lock.give(stack, held);
    switch (_route.tags6(stack, ub, tags)) {
        .none => {},
        .errno => |errno| return _socket.fail(sb, errno, "DeleteRouteTagList"),
        .wanted => |wanted| {
            if (_route6.removeMatching(stack, wanted.interface, wanted.destination, wanted.length, wanted.gateway) == 0) {
                return _socket.fail(sb, bsd.ENXIO, "DeleteRouteTagList");
            }
            return 0;
        },
    }
    if (ub.FindTagItem(bsd.RTA_DefaultGateway, tags) != null) {
        if (!_route.remove(stack, 0, 0)) return _socket.fail(sb, bsd.ENXIO, "DeleteRouteTagList");
        return 0;
    }
    const destination_item = ub.FindTagItem(bsd.RTA_Destination, tags) orelse return _socket.fail(sb, bsd.EINVAL, "DeleteRouteTagList");
    const netmask = bsd.ntohl(@truncate(ub.GetTagData(bsd.RTA_NetMask, 0xFFFF_FFFF, tags)));
    if (!_route.remove(stack, bsd.ntohl(@truncate(destination_item.data)), netmask)) return _socket.fail(sb, bsd.ENXIO, "DeleteRouteTagList");
    return 0;
}
