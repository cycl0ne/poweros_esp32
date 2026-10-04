// SPDX-License-Identifier: MIT
//! AddInterfaceTagList: an interface on a network device.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const net = sdk.devices.network;
const utility = sdk.utility;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const StackBase = _base.StackBase;
const _socket = @import("../socket/_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _netif = @import("_netif.zig");
const device = @import("device.zig");
const _route = @import("../route/_route.zig");
const _arp = @import("../arp/_arp.zig");
const _task = @import("../task/_task.zig");
const _ip6 = @import("../ip6/_ip6.zig");
const _route6 = @import("../route6/_route6.zig");
const Address = @import("../ip6/address.zig").Address;

/// An interface on a network device, up and with its routes.
///
/// SYNOPSIS:
/// ```zig
/// fn AddInterfaceTagList(base: *SocketBase, name: [*:0]const u8, tags: ?[*]const TagItem) i32
/// ```
///
/// SINCE: 1.0. LVO -100.
///
/// INPUTS:
/// - `name` - what the interface is called, "eth0": up to 15 characters,
///   not a name another interface has.
/// - `tags` - `IFA_Device` (required) and `IFA_Unit`: the network device
///   in DEVS:; `IFA_Address` (required unless `IFA_Configure` is
///   `IFCONFIGURE_DHCP`), `IFA_NetMask`, `IFA_Gateway`: the interface's
///   address on its net, the net's mask (255.255.255.0 unless given) and
///   a gateway made the default route; `IFA_MTU`: less than the link
///   takes; `IFA_Reads`, `IFA_Writes`: how many requests the stack keeps
///   with the device; `IFA_IPv6` (`IFIPV6_AUTO` unless given, or
///   `IFIPV6_OFF`), `IFA_InterfaceID` (`IFID_STABLE` unless given, or
///   `IFID_EUI64`) and `IFA_StableSecret`: whether the interface speaks
///   IPv6, and how its addresses end; `IFA_Address6`, `IFA_Prefix6` and
///   `IFA_Gateway6`: an IPv6 address of its own, its prefix on the link
///   and a router for the default route (`IFIPV6_FIXED` takes no address
///   from a router's prefix). Stack-wide: `IFA_NameServer` (any number),
///   `IFA_NameServer6` (the same, IPv6), `IFA_Domain`, `IFA_TCPSendSpace`,
///   `IFA_TCPRecvSpace`.
///
/// RESULT:
/// 0, or -1 with Errno(): `EINVAL` (a tag missing or a name too long),
/// `EADDRINUSE` (the name is taken, or the device's unit has an
/// interface already), `ENOBUFS` (no interface free),
/// `ENXIO` (the device would not open, or would not go on line),
/// `EPFNOSUPPORT` (the device's link is not Ethernet), `ENOMEM`.
///
/// BEHAVIOR:
/// The device is opened with the stack's copy calls, asked what its link
/// is, and put on line with the address it came with, unless it is on
/// line already. The first interface on a device starts the stack task,
/// which keeps reads outstanding on it from then on - of each eight one
/// for ARP, three for IPv6 when the interface speaks it, the rest for
/// IPv4 - as many as the link's speed calls for unless the tags say: 8,
/// 24 from 10 Mbit/s, 32 from 100 Mbit/s. A frame that finds no read of
/// its type waiting is lost, so a burst - a TCP window, a packet's
/// fragments - needs that many. An
/// interface that speaks IPv6 is given its link-local address; a stable
/// identifier needs crypto.library, which is opened for it, and without
/// which the link's EUI-64 is taken. Without `IFA_StableSecret` the
/// secret is random, and the addresses change at the next boot. A route
/// to the interface's own net is added, and the default route through the
/// gateway if there is one, and every station on the net is told where
/// the address is (a gratuitous ARP).
///
/// CONTEXT:
/// - Waits: yes: the device is opened and asked, and the task started.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a process, to load the device from DEVS:.
///
/// OWNERSHIP:
/// The interface is the stack's until RemoveInterface; while it is there
/// the library stays in memory. The tags are read and not kept.
///
/// NOTES:
/// Only Ethernet links for now.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemoveInterface`, sdk/devices/network.zig
///
/// EXAMPLES:
/// ```zig
/// const tags = [_]TagItem{
///     .{ .tag = bsd.IFA_Device, .data = @intFromPtr("networks/openeth.device") },
///     .{ .tag = bsd.IFA_Address, .data = sb.Inet_Addr("10.0.2.15") },
///     .{ .tag = bsd.IFA_Gateway, .data = sb.Inet_Addr("10.0.2.2") },
///     .{},
/// };
/// if (sb.AddInterfaceTagList("eth0", &tags) < 0) return sb.Errno();
/// ```
pub fn AddInterfaceTagList(sb: *SocketBase, name: [*:0]const u8, tags: ?[*]const utility.TagItem) i32 {
    const stack = sb.stack;
    // The machine's name, for the DHCP request this may start.
    @import("../names/_names.zig").loadHostName(sb);
    const sys = sb.sys_base;
    const ub = stack.utility.?;
    const device_name: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(bsd.IFA_Device, 0, tags));
    const unit: u32 = @truncate(ub.GetTagData(bsd.IFA_Unit, 0, tags));
    const address = bsd.ntohl(@truncate(ub.GetTagData(bsd.IFA_Address, 0, tags)));
    const netmask = bsd.ntohl(@truncate(ub.GetTagData(bsd.IFA_NetMask, bsd.htonl(0xFFFF_FF00), tags)));
    const gateway = bsd.ntohl(@truncate(ub.GetTagData(bsd.IFA_Gateway, 0, tags)));
    const dhcp = ub.GetTagData(bsd.IFA_Configure, bsd.IFCONFIGURE_FIXED, tags) == bsd.IFCONFIGURE_DHCP;
    const mtu: u32 = @truncate(ub.GetTagData(bsd.IFA_MTU, 0, tags));
    const ipv6_mode = ub.GetTagData(bsd.IFA_IPv6, bsd.IFIPV6_AUTO, tags);
    const ipv6 = ipv6_mode != bsd.IFIPV6_OFF;
    const address6: ?*align(1) const bsd.in6_addr = @ptrFromInt(ub.GetTagData(bsd.IFA_Address6, 0, tags));
    const prefix6: u8 = @intCast(@min(ub.GetTagData(bsd.IFA_Prefix6, 64, tags), 128));
    const gateway6: ?*align(1) const bsd.in6_addr = @ptrFromInt(ub.GetTagData(bsd.IFA_Gateway6, 0, tags));
    const identifier: u8 = if (ub.GetTagData(bsd.IFA_InterfaceID, bsd.IFID_STABLE, tags) == bsd.IFID_EUI64) bsd.IFID_EUI64 else bsd.IFID_STABLE;
    const given_secret: ?[*]const u8 = @ptrFromInt(ub.GetTagData(bsd.IFA_StableSecret, 0, tags));
    var name_length: usize = 0;
    while (name[name_length] != 0) name_length += 1;
    var device_length: usize = 0;
    if (device_name) |text| {
        while (text[device_length] != 0) device_length += 1;
    }
    if (device_name == null or device_length >= 64 or (address == 0 and !dhcp) or name_length == 0 or name_length >= bsd.IFNAMSIZ) {
        return _socket.fail(sb, bsd.EINVAL, "AddInterfaceTagList");
    }
    {
        const held = _lock.take(stack);
        defer _lock.give(stack, held);
        if (_netif.named(stack, name) != null or onDevice(stack, device_name.?, unit)) return _socket.fail(sb, bsd.EADDRINUSE, "AddInterfaceTagList");
        if (_netif.free(stack) == null) return _socket.fail(sb, bsd.ENOBUFS, "AddInterfaceTagList");
    }
    settings(stack, tags);
    if (ipv6 and identifier == bsd.IFID_STABLE) openCrypto(stack);
    if (!_task.start(stack)) return _socket.fail(sb, bsd.ENOMEM, "AddInterfaceTagList");

    const memory = sys.AllocMem(@sizeOf(device.Device), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse
        return _socket.fail(sb, bsd.ENOMEM, "AddInterfaceTagList");
    const link: *device.Device = @ptrCast(@alignCast(memory));
    const port = sys.CreateMsgPort() orelse {
        sys.FreeMem(memory, @sizeOf(device.Device));
        return _socket.fail(sb, bsd.ENOMEM, "AddInterfaceTagList");
    };
    const refused = open(stack, link, device_name.?, unit, port);
    sys.DeleteMsgPort(port);
    link.opened.req.message.reply_port = null;
    if (refused != 0) {
        sys.FreeMem(memory, @sizeOf(device.Device));
        return _socket.fail(sb, refused, "AddInterfaceTagList");
    }
    @memcpy(link.name[0..device_length], device_name.?[0..device_length]);
    link.unit = unit;
    const bps = link.bps();
    link.reads = @min(@as(u32, @truncate(ub.GetTagData(bsd.IFA_Reads, if (bps >= 100_000_000) 32 else if (bps >= 10_000_000) 24 else 8, tags))), device.reads_max);
    link.writes = @min(@as(u32, @truncate(ub.GetTagData(bsd.IFA_Writes, if (bps >= 100_000_000) 8 else if (bps >= 10_000_000) 4 else 2, tags))), device.writes_max);
    if (link.reads == 0) link.reads = 1;
    if (link.writes == 0) link.writes = 1;

    const held = _lock.take(stack);
    defer _lock.give(stack, held);
    const interface = if (_netif.named(stack, name) == null and !onDevice(stack, device_name.?, unit)) _netif.free(stack) else null;
    const slot = interface orelse {
        sys.CloseDevice(&link.opened.req);
        sys.FreeMem(memory, @sizeOf(device.Device));
        return _socket.fail(sb, bsd.EADDRINUSE, "AddInterfaceTagList");
    };
    slot.* = .{
        .address = address,
        .netmask = netmask,
        .broadcast = address | ~netmask,
        .mtu = if (mtu != 0) @min(mtu, link.mtu) else link.mtu,
        .used = 1,
        .up = 1,
        .dhcp = @intFromBool(dhcp),
        .hardware = link.station,
        .transmit = &device.transmit,
        .device = link,
    };
    @memcpy(slot.name[0..name_length], name[0..name_length]);
    slot.ip6.identifier = identifier;
    if (given_secret) |secret| {
        @memcpy(&slot.ip6.secret, secret[0..bsd.IFSECRET_BYTES]);
    } else if (stack.crypto) |cb| {
        cb.RandomBytes(&slot.ip6.secret, bsd.IFSECRET_BYTES);
    }
    // The reads for IPv6 are sent with the others; the addresses come once
    // the device can join their groups.
    slot.ip6.enabled = @intFromBool(ipv6);
    slot.ip6.autoconf = @intFromBool(ipv6_mode != bsd.IFIPV6_FIXED);
    link.interface = slot;
    if (address != 0) _ = _route.add(stack, address, netmask, 0, slot);
    if (gateway != 0) _ = _route.setDefault(stack, gateway);
    // The interface keeps the library, so the task and the code stay.
    @import("../task/_task.zig").holdLibrary(stack, 1);
    device.start(stack, link, &stack.port);
    if (ipv6) {
        _ip6.start(stack, slot);
        if (address6) |given| {
            const own: Address = .{ .bytes = given.s6_addr };
            _ = _ip6.addAddress(stack, slot, own, prefix6, .tentative);
            if (prefix6 < 128) _ = _route6.set(stack, slot, own, prefix6, Address.any, .manual, 0);
        }
        if (gateway6) |given| _ = _route6.set(stack, slot, Address.any, 0, .{ .bytes = given.s6_addr }, .manual, 0);
    }
    if (address != 0) _arp.announce(stack, slot);
    if (dhcp) @import("../dhcp/_dhcp.zig").start(stack, slot);
    return 0;
}

/// crypto.library opened for the stack, the first time an interface wants
/// it; the stack keeps it until it goes.
fn openCrypto(stack: *StackBase) void {
    const sys = stack.sys_base;
    const held = _lock.take(stack);
    const wanted = stack.crypto == null;
    _lock.give(stack, held);
    if (!wanted) return;
    const opened = sys.OpenLibrary(sdk.crypto.CRYPTONAME, 1) orelse return;
    const again = _lock.take(stack);
    defer _lock.give(stack, again);
    if (stack.crypto == null) {
        stack.crypto = @ptrCast(opened);
    } else {
        sys.CloseLibrary(opened);
    }
}

/// Whether an interface runs on `device_name`'s `unit` already: one link,
/// one interface.
fn onDevice(stack: *StackBase, device_name: [*:0]const u8, unit: u32) bool {
    for (&stack.interfaces) |*interface| {
        if (interface.used == 0) continue;
        const link: *device.Device = @ptrCast(@alignCast(interface.device orelse continue));
        if (link.unit != unit) continue;
        var at: usize = 0;
        while (at < link.name.len and link.name[at] == device_name[at] and device_name[at] != 0) at += 1;
        if (at < link.name.len and link.name[at] == device_name[at]) return true;
    }
    return false;
}

/// The stack-wide settings an interface's tags carry: name servers, the
/// domain, the TCP ring sizes.
fn settings(stack: *StackBase, tags: ?[*]const utility.TagItem) void {
    const ub = stack.utility.?;
    const held = _lock.take(stack);
    defer _lock.give(stack, held);
    var walk = tags;
    while (ub.NextTagItem(&walk)) |item| {
        switch (item.tag) {
            bsd.IFA_NameServer => _ = @import("../names/_names.zig").addServer(stack, Address.fromV4(bsd.ntohl(@truncate(item.data)))),
            bsd.IFA_NameServer6 => if (@as(?*align(1) const bsd.in6_addr, @ptrFromInt(item.data))) |server| {
                _ = @import("../names/_names.zig").addServer(stack, .{ .bytes = server.s6_addr });
            },
            bsd.IFA_Domain => {
                const text: [*:0]const u8 = @ptrFromInt(item.data);
                var at: usize = 0;
                while (at + 1 < stack.domain.len and text[at] != 0) : (at += 1) stack.domain[at] = text[at];
                stack.domain[at] = 0;
            },
            bsd.IFA_TCPSendSpace => stack.tcp_send_space = @truncate(item.data),
            bsd.IFA_TCPRecvSpace => stack.tcp_recv_space = @truncate(item.data),
            else => {},
        }
    }
}

/// The device opened with the stack's copy calls, asked what it is, and
/// on line: 0, or the errno that says why not.
fn open(stack: *StackBase, link: *device.Device, device_name: [*:0]const u8, unit: u32, port: *exec.MsgPort) i32 {
    const sys = stack.sys_base;
    const buffers = device.bufferTags();
    const req = &link.opened;
    req.* = .{};
    req.req.message.reply_port = port;
    req.req.message.length = @sizeOf(net.IOSana2Req);
    req.buffer_management = @constCast(&buffers);
    if (sys.OpenDevice(device_name, unit, &req.req, 0) != 0) return bsd.ENXIO;

    var query: net.Sana2DeviceQuery = .{ .size_available = @sizeOf(net.Sana2DeviceQuery) };
    req.req.command = net.S2_DEVICEQUERY;
    req.stat_data = &query;
    if (sys.DoIO(&req.req) != 0 or query.hardware_type != net.S2WireType_Ethernet or query.addr_field_size != 48) {
        sys.CloseDevice(&req.req);
        return bsd.EPFNOSUPPORT;
    }
    link.mtu = query.mtu;
    link.bps_low = @truncate(query.bps);
    link.bps_high = @truncate(query.bps >> 32);

    req.req.command = net.S2_GETSTATIONADDRESS;
    _ = sys.DoIO(&req.req);
    const factory: [6]u8 = req.dst_addr[0..6].*;
    link.station = req.src_addr[0..6].*;
    req.req.command = net.S2_CONFIGINTERFACE;
    req.src_addr = @splat(0);
    req.src_addr[0..6].* = factory;
    _ = sys.DoIO(&req.req);
    if (req.req.err == 0) {
        link.station = factory;
    } else if (req.wire_error == net.S2WERR_IS_CONFIGURED) {
        // Configured before: it keeps its address, and may only need
        // putting back on line.
        req.req.command = net.S2_ONLINE;
        _ = sys.DoIO(&req.req);
        if (req.req.err != 0 and req.wire_error != net.S2WERR_UNIT_ONLINE) {
            sys.CloseDevice(&req.req);
            return bsd.ENXIO;
        }
    } else {
        sys.CloseDevice(&req.req);
        return bsd.ENXIO;
    }
    req.stat_data = null;
    return 0;
}
