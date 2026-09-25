// SPDX-License-Identifier: MIT
//! AddRouteTagList: a route to a net, or the default route.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const utility = sdk.utility;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("../socket/_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _route = @import("_route.zig");

/// A route added: to a net or a host through a gateway, or the default
/// route.
///
/// SYNOPSIS:
/// ```zig
/// fn AddRouteTagList(base: *SocketBase, tags: ?[*]const TagItem) i32
/// ```
///
/// SINCE: 1.0. LVO -148.
///
/// INPUTS:
/// - `tags` - `RTA_DefaultGateway` alone; or `RTA_Destination`,
///   `RTA_NetMask` (a host unless given) and `RTA_Gateway`. Addresses in
///   network order.
///
/// RESULT:
/// 0, or -1 with Errno(): `EINVAL` (no destination or no gateway),
/// `ENETUNREACH` (the gateway is on no interface's net), `ENOBUFS` (the
/// route list is full).
///
/// BEHAVIOR:
/// A route goes out of the interface whose net holds its gateway. A
/// default route replaces the one there was. Of the routes that hold an
/// address, the one with the longest netmask is taken.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Forbid: not held.
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
/// ```
pub fn AddRouteTagList(sb: *SocketBase, tags: ?[*]const utility.TagItem) i32 {
    const stack = sb.stack;
    const ub = stack.utility.?;
    const held = _lock.take(stack);
    defer _lock.give(stack, held);
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
