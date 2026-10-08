// SPDX-License-Identifier: MIT
//! ConfigureInterfaceTagList: a running interface's address, net, gateway,
//! MTU, IPv6 address or privacy addresses changed, or its device taken off
//! its link and put back.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const net = sdk.devices.network;
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
const _ip6 = @import("../ip6/_ip6.zig");
const _route6 = @import("../route6/_route6.zig");
const Address = @import("../ip6/address.zig").Address;

/// A running interface changed: its address, its net, the default route
/// through it, its MTU, its IPv6 address, its privacy addresses, whether
/// its device is on its link.
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
///   (made the default route), `IFA_MTU`, `IFA_Address6` with
///   `IFA_Prefix6` (64 unless given), `IFA_PrivacyAddresses` (not 0 for
///   on), `IFA_State` (`IFSTATE_UP` set or clear). What is not given
///   stays.
///
/// RESULT:
/// 0, or -1 with Errno(): `ENXIO` (no such interface), `EINVAL` (lo0, a
/// gateway on no interface's net, an IPv6 address on an interface that
/// does not speak IPv6, or one that is a group), `ENOBUFS` (the interface
/// holds as many IPv6 addresses as it can), `EIO` (the device would not go
/// on or off its link), `ENOMEM`.
///
/// BEHAVIOR:
/// A new address or netmask replaces the route to the interface's own
/// net, and a new address is announced to the net (a gratuitous ARP). The
/// MTU cannot go above what the link takes. Sockets bound to the old
/// address stay, and send from an address the interface no longer has.
///
/// `IFA_State` without `IFSTATE_UP` sends the device S2_OFFLINE: the
/// interface is down, nothing goes out of it and nothing comes in, and
/// it keeps its address and routes. With `IFSTATE_UP` the device gets
/// S2_ONLINE and the interface is up again; if its address is DHCP's,
/// the lease is renewed at once, since the link may be another one now.
/// A device already in the state asked for is left as it is.
///
/// `IFA_Address6` replaces the IPv6 address given by hand - by it, or
/// by AddInterfaceTagList's - and the route to its prefix on the link
/// (none for a prefix of 128); the new one is checked for a duplicate
/// before it is used. `::` takes the address away. The link-local address
/// and those from routers' prefixes and from DHCPv6 stay.
///
/// `IFA_PrivacyAddresses` turned on makes a temporary address for each
/// prefix at once; turned off, every temporary address goes, and with it
/// what was connected from it.
///
/// CONTEXT:
/// - Waits: for the stack's lock, and for the device with `IFA_State`.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do; `IFA_State` makes a message port.
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
    if (ub.FindTagItem(bsd.IFA_Address6, tags)) |item| {
        const length: u8 = @intCast(@min(ub.GetTagData(bsd.IFA_Prefix6, 64, tags), 128));
        const errno = setAddress6(stack, interface, @ptrFromInt(item.data), length);
        if (errno != 0) return _socket.fail(sb, errno, "ConfigureInterfaceTagList");
    }
    if (ub.FindTagItem(bsd.IFA_PrivacyAddresses, tags)) |item| {
        if (interface.ip6.enabled != 0) @import("../nd/privacy.zig").set(stack, interface, item.data != 0, @import("../timer/_timer.zig").clock(stack));
    }
    if (ub.FindTagItem(bsd.IFA_State, tags)) |item| {
        const errno = setState(stack, interface, item.data & bsd.IFSTATE_UP != 0);
        if (errno != 0) return _socket.fail(sb, errno, "ConfigureInterfaceTagList");
    }
    return 0;
}

/// The interface's device put on its link or taken off it, and the
/// interface up or down with it: 0, or an errno. Under the lock: the
/// device answers without it.
fn setState(stack: *StackBase, interface: *Interface, online: bool) i32 {
    const sys = stack.sys_base;
    const link: *device.Device = @ptrCast(@alignCast(interface.device orelse {
        interface.up = @intFromBool(online);
        return 0;
    }));
    const port = sys.CreateMsgPort() orelse return bsd.ENOMEM;
    defer sys.DeleteMsgPort(port);
    var req = link.opened;
    req.req.message.reply_port = port;
    req.req.command = if (online) net.S2_ONLINE else net.S2_OFFLINE;
    req.req.flags = 0;
    if (sys.DoIO(&req.req) != 0) {
        const already = if (online) net.S2WERR_UNIT_ONLINE else net.S2WERR_UNIT_OFFLINE;
        if (req.wire_error != already) return bsd.EIO;
    }
    device.setLink(stack, link, online);
    // The stack task sends the reads that waited.
    stack.rethink();
    return 0;
}

/// The IPv6 address given by hand on `interface` replaced by `given`/
/// `length` and its prefix's route - or only taken away, for none or
/// `::`: 0, or the errno. Under the lock.
fn setAddress6(stack: *StackBase, interface: *Interface, given: ?*align(1) const bsd.in6_addr, length: u8) i32 {
    if (interface.ip6.enabled == 0) return bsd.EINVAL;
    const wanted: Address = if (given) |address| .{ .bytes = address.s6_addr } else Address.any;
    if (wanted.isMulticast()) return bsd.EINVAL;
    for (&interface.ip6.addresses) |*entry| {
        if (entry.state == .unused or entry.autoconf != 0 or entry.dhcp6 != 0 or entry.address.isLinkLocal()) continue;
        // Given again as it is: nothing changes.
        if (entry.address.eql(wanted) and entry.prefix_length == length) return 0;
        if (entry.prefix_length < 128) _ = _route6.remove(stack, interface, entry.address, entry.prefix_length, Address.any);
        _ip6.removeAddress(stack, entry);
    }
    if (wanted.isUnspecified()) return 0;
    _ = _ip6.addAddress(stack, interface, wanted, length, .tentative) orelse return bsd.ENOBUFS;
    if (length < 128) _ = _route6.set(stack, interface, wanted, length, Address.any, .manual, 0);
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
