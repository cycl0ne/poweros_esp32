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
///   in DEVS:; `IFA_Address` (required), `IFA_NetMask`, `IFA_Gateway`: the
///   interface's address on its net, the net's mask (255.255.255.0 unless
///   given) and a gateway made the default route; `IFA_Reads`,
///   `IFA_Writes`: how many requests the stack keeps with the device.
///
/// RESULT:
/// 0, or -1 with Errno(): `EINVAL` (a tag missing or a name too long),
/// `EADDRINUSE` (the name is taken), `ENOBUFS` (no interface free),
/// `ENXIO` (the device would not open, or would not go on line),
/// `EPFNOSUPPORT` (the device's link is not Ethernet), `ENOMEM`.
///
/// BEHAVIOR:
/// The device is opened with the stack's copy calls, asked what its link
/// is, and put on line with the address it came with, unless it is on
/// line already. The first interface on a device starts the stack task,
/// which keeps reads outstanding on it from then on - a quarter of them
/// for ARP, the rest for IPv4 - as many as the link's speed calls for
/// unless the tags say. A route to the interface's own net is added, and
/// the default route through the gateway if there is one, and every
/// station on the net is told where the address is (a gratuitous ARP).
///
/// CONTEXT:
/// - Waits: yes: the device is opened and asked, and the task started.
/// - Interrupts: no.
/// - Forbid: must not be held.
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
    const sys = sb.sys_base;
    const ub = stack.utility.?;
    const device_name: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(bsd.IFA_Device, 0, tags));
    const unit: u32 = @truncate(ub.GetTagData(bsd.IFA_Unit, 0, tags));
    const address = bsd.ntohl(@truncate(ub.GetTagData(bsd.IFA_Address, 0, tags)));
    const netmask = bsd.ntohl(@truncate(ub.GetTagData(bsd.IFA_NetMask, bsd.htonl(0xFFFF_FF00), tags)));
    const gateway = bsd.ntohl(@truncate(ub.GetTagData(bsd.IFA_Gateway, 0, tags)));
    var name_length: usize = 0;
    while (name[name_length] != 0) name_length += 1;
    if (device_name == null or address == 0 or name_length == 0 or name_length >= bsd.IFNAMSIZ) {
        return _socket.fail(sb, bsd.EINVAL, "AddInterfaceTagList");
    }
    {
        const held = _lock.take(stack);
        defer _lock.give(stack, held);
        if (_netif.named(stack, name) != null) return _socket.fail(sb, bsd.EADDRINUSE, "AddInterfaceTagList");
        if (_netif.free(stack) == null) return _socket.fail(sb, bsd.ENOBUFS, "AddInterfaceTagList");
    }
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
    const bps = link.bps();
    link.reads = @min(@as(u32, @truncate(ub.GetTagData(bsd.IFA_Reads, if (bps >= 100_000_000) 16 else if (bps >= 10_000_000) 8 else 4, tags))), device.reads_max);
    link.writes = @min(@as(u32, @truncate(ub.GetTagData(bsd.IFA_Writes, if (bps >= 100_000_000) 8 else if (bps >= 10_000_000) 4 else 2, tags))), device.writes_max);
    if (link.reads == 0) link.reads = 1;
    if (link.writes == 0) link.writes = 1;

    const held = _lock.take(stack);
    defer _lock.give(stack, held);
    const interface = if (_netif.named(stack, name) == null) _netif.free(stack) else null;
    const slot = interface orelse {
        sys.CloseDevice(&link.opened.req);
        sys.FreeMem(memory, @sizeOf(device.Device));
        return _socket.fail(sb, bsd.EADDRINUSE, "AddInterfaceTagList");
    };
    slot.* = .{
        .address = address,
        .netmask = netmask,
        .broadcast = address | ~netmask,
        .mtu = link.mtu,
        .used = 1,
        .up = 1,
        .hardware = link.station,
        .transmit = &device.transmit,
        .device = link,
    };
    @memcpy(slot.name[0..name_length], name[0..name_length]);
    link.interface = slot;
    _ = _route.add(stack, address, netmask, 0, slot);
    if (gateway != 0) _ = _route.add(stack, 0, 0, gateway, slot);
    // The interface keeps the library, so the task and the code stay.
    sys.Forbid();
    stack.lib.open_cnt += 1;
    sys.Permit();
    device.start(stack, link, &stack.port);
    _arp.announce(stack, slot);
    return 0;
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
