// SPDX-License-Identifier: MIT
//! QueryInterfaceTagList: what an interface is.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const utility = sdk.utility;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("../socket/_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _netif = @import("_netif.zig");
const _route = @import("../route/_route.zig");
const device = @import("device.zig");

/// What an interface is, each answer where its tag points.
///
/// SYNOPSIS:
/// ```zig
/// fn QueryInterfaceTagList(base: *SocketBase, name: [*:0]const u8, tags: ?[*]const TagItem) i32
/// ```
///
/// SINCE: 1.0. LVO -136.
///
/// INPUTS:
/// - `name` - the interface: "lo0", or as it was added.
/// - `tags` - each an `IFQ_*` tag with a pointer to where its answer
///   goes: `IFQ_Address`, `IFQ_NetMask`, `IFQ_Broadcast`, `IFQ_Gateway`
///   (u32, network order), `IFQ_MTU`, `IFQ_State` (IFSTATE_*),
///   `IFQ_DeviceUnit`, `IFQ_PacketsDropped` (u32), `IFQ_PacketsSent`,
///   `IFQ_PacketsReceived`, `IFQ_Speed` (u64), `IFQ_HardwareAddress`
///   ([6]u8), `IFQ_DeviceName` ([*:0]const u8, or null for lo0).
///
/// RESULT:
/// 0, or -1 with Errno(): `ENXIO` (no such interface), `EINVAL` (a tag
/// there is not, or one with no pointer).
///
/// BEHAVIOR:
/// The answers are taken together, under the stack's lock, so they
/// belong to one moment.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Forbid: not held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `IFQ_DeviceName`'s string is the interface's, good while it is there.
///
/// NOTES:
/// How AddNetInterface learns the address DHCP got.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainInterfaceList`, `ConfigureInterfaceTagList`
///
/// EXAMPLES:
/// ```zig
/// var address: u32 = 0;
/// const tags = [_]TagItem{ .{ .tag = bsd.IFQ_Address, .data = @intFromPtr(&address) }, .{} };
/// if (sb.QueryInterfaceTagList("eth0", &tags) == 0) _ = Printf(dl, "%s\n", .{sb.Inet_NtoA(address)});
/// ```
pub fn QueryInterfaceTagList(sb: *SocketBase, name: [*:0]const u8, tags: ?[*]const utility.TagItem) i32 {
    const stack = sb.stack;
    const ub = stack.utility.?;
    const held = _lock.take(stack);
    defer _lock.give(stack, held);
    const interface = _netif.named(stack, name) orelse return _socket.fail(sb, bsd.ENXIO, "QueryInterfaceTagList");
    const link: ?*device.Device = @ptrCast(@alignCast(interface.device));
    var walk = tags;
    while (ub.NextTagItem(&walk)) |item| {
        if (item.data == 0) return _socket.fail(sb, bsd.EINVAL, "QueryInterfaceTagList");
        const word: *align(1) u32 = @ptrFromInt(item.data);
        const long: *align(1) u64 = @ptrFromInt(item.data);
        switch (item.tag) {
            bsd.IFQ_Address => word.* = bsd.htonl(interface.address),
            bsd.IFQ_NetMask => word.* = bsd.htonl(interface.netmask),
            bsd.IFQ_Broadcast => word.* = bsd.htonl(interface.broadcast),
            bsd.IFQ_Gateway => word.* = bsd.htonl(_route.defaultThrough(stack, interface)),
            bsd.IFQ_MTU => word.* = interface.mtu,
            bsd.IFQ_State => word.* = state(interface),
            bsd.IFQ_DeviceUnit => word.* = if (link) |dev| dev.unit else 0,
            bsd.IFQ_PacketsDropped => word.* = interface.dropped,
            bsd.IFQ_PacketsSent => long.* = interface.sent,
            bsd.IFQ_PacketsReceived => long.* = interface.received,
            bsd.IFQ_Speed => long.* = if (link) |dev| dev.bps() else 0,
            bsd.IFQ_HardwareAddress => @as(*align(1) [6]u8, @ptrFromInt(item.data)).* = interface.hardware,
            bsd.IFQ_DeviceName => @as(*align(1) ?[*:0]const u8, @ptrFromInt(item.data)).* = if (link) |dev| @ptrCast(&dev.name) else null,
            else => return _socket.fail(sb, bsd.EINVAL, "QueryInterfaceTagList"),
        }
    }
    return 0;
}

fn state(interface: *const _netif.Interface) u32 {
    var bits: u32 = 0;
    if (interface.up != 0) bits |= bsd.IFSTATE_UP;
    if (interface.loopback != 0) bits |= bsd.IFSTATE_LOOPBACK;
    if (interface.dhcp != 0) bits |= bsd.IFSTATE_DHCP;
    if (interface.bound != 0) bits |= bsd.IFSTATE_BOUND;
    if (interface.link_local != 0) bits |= bsd.IFSTATE_LINKLOCAL;
    return bits;
}
