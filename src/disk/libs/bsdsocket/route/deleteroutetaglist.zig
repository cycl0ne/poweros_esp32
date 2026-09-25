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

/// A route taken away: the one to a net or host, or the default route.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteRouteTagList(base: *SocketBase, tags: ?[*]const TagItem) i32
/// ```
///
/// SINCE: 1.0. LVO -152.
///
/// INPUTS:
/// - `tags` - `RTA_Destination` and `RTA_NetMask` (a host unless given);
///   or `RTA_DefaultGateway`, with any value, for the default route.
///
/// RESULT:
/// 0, or -1 with Errno(): `EINVAL` (no destination), `ENXIO` (there is no
/// such route).
///
/// BEHAVIOR:
/// The route is found by its destination and netmask, as it was added.
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
    if (ub.FindTagItem(bsd.RTA_DefaultGateway, tags) != null) {
        if (!_route.remove(stack, 0, 0)) return _socket.fail(sb, bsd.ENXIO, "DeleteRouteTagList");
        return 0;
    }
    const destination_item = ub.FindTagItem(bsd.RTA_Destination, tags) orelse return _socket.fail(sb, bsd.EINVAL, "DeleteRouteTagList");
    const netmask = bsd.ntohl(@truncate(ub.GetTagData(bsd.RTA_NetMask, 0xFFFF_FFFF, tags)));
    if (!_route.remove(stack, bsd.ntohl(@truncate(destination_item.data)), netmask)) return _socket.fail(sb, bsd.ENXIO, "DeleteRouteTagList");
    return 0;
}
