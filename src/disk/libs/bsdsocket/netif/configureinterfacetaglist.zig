// SPDX-License-Identifier: MIT
//! ConfigureInterfaceTagList: a running interface's address, net, gateway
//! or MTU changed.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const utility = sdk.utility;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const StackBase = _base.StackBase;
const _socket = @import("../socket/_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _netif = @import("_netif.zig");
const Interface = _netif.Interface;
const _route = @import("../route/_route.zig");
const _arp = @import("../arp/_arp.zig");
const device = @import("device.zig");

/// A running interface changed: its address, its net, the default route
/// through it, its MTU.
///
/// SYNOPSIS:
/// ```zig
/// fn ConfigureInterfaceTagList(base: *SocketBase, name: [*:0]const u8, tags: ?[*]const TagItem) i32
/// ```
///
/// SINCE: 1.0. LVO -132.
///
/// INPUTS:
/// - `name` - the interface, as it was added.
/// - `tags` - `IFA_Address`, `IFA_NetMask` (network order), `IFA_Gateway`
///   (made the default route), `IFA_MTU`. What is not given stays.
///
/// RESULT:
/// 0, or -1 with Errno(): `ENXIO` (no such interface), `EINVAL` (lo0, or
/// a gateway on no interface's net).
///
/// BEHAVIOR:
/// A new address or netmask replaces the route to the interface's own
/// net, and a new address is announced to the net (a gratuitous ARP). The
/// MTU cannot go above what the link takes. Sockets bound to the old
/// address stay, and send from an address the interface no longer has.
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
/// What DHCP does to an interface it has an address for, a program can do
/// with this by hand.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddInterfaceTagList`, `QueryInterfaceTagList`, `AddRouteTagList`
///
/// EXAMPLES:
/// ```zig
/// const tags = [_]TagItem{ .{ .tag = bsd.IFA_Address, .data = sb.Inet_Addr("10.0.2.16") }, .{} };
/// _ = sb.ConfigureInterfaceTagList("eth0", &tags);
/// ```
pub fn ConfigureInterfaceTagList(sb: *SocketBase, name: [*:0]const u8, tags: ?[*]const utility.TagItem) i32 {
    const stack = sb.stack;
    const ub = stack.utility.?;
    const held = _lock.take(stack);
    defer _lock.give(stack, held);
    const interface = _netif.named(stack, name) orelse return _socket.fail(sb, bsd.ENXIO, "ConfigureInterfaceTagList");
    if (interface.loopback != 0) return _socket.fail(sb, bsd.EINVAL, "ConfigureInterfaceTagList");
    const address = bsd.ntohl(@truncate(ub.GetTagData(bsd.IFA_Address, bsd.htonl(interface.address), tags)));
    const netmask = bsd.ntohl(@truncate(ub.GetTagData(bsd.IFA_NetMask, bsd.htonl(interface.netmask), tags)));
    setAddress(stack, interface, address, netmask);
    if (ub.FindTagItem(bsd.IFA_MTU, tags)) |item| {
        const link: ?*device.Device = @ptrCast(@alignCast(interface.device));
        const most = if (link) |dev| dev.mtu else interface.mtu;
        if (item.data != 0) interface.mtu = @min(@as(u32, @truncate(item.data)), most);
    }
    if (ub.FindTagItem(bsd.IFA_Gateway, tags)) |item| {
        if (!_route.setDefault(stack, bsd.ntohl(@truncate(item.data)))) return _socket.fail(sb, bsd.EINVAL, "ConfigureInterfaceTagList");
    }
    return 0;
}

/// An interface given `address` on the net `netmask`: its own net's route
/// made again, and the address announced. Under the lock.
pub fn setAddress(stack: *StackBase, interface: *Interface, address: u32, netmask: u32) void {
    if (address == interface.address and netmask == interface.netmask) return;
    if (interface.address != 0) _ = _route.remove(stack, interface.address, interface.netmask);
    interface.address = address;
    interface.netmask = netmask;
    interface.broadcast = address | ~netmask;
    if (address == 0) return;
    _ = _route.add(stack, address, netmask, 0, interface);
    _arp.announce(stack, interface);
}
