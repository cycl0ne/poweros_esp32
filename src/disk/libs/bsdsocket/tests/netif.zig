// SPDX-License-Identifier: MIT
//! Host tests of the interface calls: querying and changing an interface,
//! the list of them, routes and name servers - on an interface the test
//! adds by hand, whose link nothing listens to.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const TagItem = sdk.utility.TagItem;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const bsdsocket = @import("../bsdsocket_init.zig");
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _route = @import("../route/_route.zig");
const _arp = @import("../arp/_arp.zig");
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;

const testing = std.testing;

fn discard(stack: *StackBase, _: *Interface, frame: *Frame, _: *const [6]u8, _: u16) i32 {
    stack.frames.give(stack.sys_base, frame);
    return 0;
}

const Rig = struct {
    kub: *utility_library.UtilityBase,
    lib: *exec.Library,
    stack: *StackBase,
    sb: *SocketBase,

    fn init() !Rig {
        const kub = try utility_library.setUp();
        const sys = kexec.SysBase.iface();
        const made = kexec.InitResident(kexec.SysBase, &bsdsocket.bsdsocket_library_tag, null) orelse return error.NoLibrary;
        const lib: *exec.Library = @ptrCast(@alignCast(made));
        const stack = _base.stackBase(lib);
        const interface = _netif.free(stack).?;
        interface.* = .{
            .address = 0xC0A8_0114,
            .netmask = 0xFFFF_FF00,
            .broadcast = 0xC0A8_01FF,
            .mtu = 1500,
            .used = 1,
            .up = 1,
            .hardware = .{ 2, 0, 0, 0, 0, 7 },
            .transmit = &discard,
        };
        @memcpy(interface.name[0..4], "eth0");
        _ = _route.add(stack, interface.address, interface.netmask, 0, interface);
        const sb: *SocketBase = @ptrCast(sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse return error.NoBase);
        return .{ .kub = kub, .lib = lib, .stack = stack, .sb = sb };
    }

    fn deinit(rig: *Rig) !void {
        const sys = kexec.SysBase.iface();
        const interface = _netif.named(rig.stack, "eth0").?;
        _arp.forget(rig.stack, interface);
        _route.removeAll(rig.stack, interface);
        interface.* = .{};
        sys.CloseLibrary(rig.sb.lib());
        _ = sys.RemLibrary(rig.lib);
        try utility_library.tearDown(rig.kub);
        kexec.deinit();
    }
};

test "an interface says what it is, and is changed while it runs" {
    var rig = try Rig.init();
    const sb = rig.sb;
    var address: u32 = 0;
    var netmask: u32 = 0;
    var gateway: u32 = 0;
    var mtu: u32 = 0;
    var state: u32 = 0;
    var hardware: [6]u8 = undefined;
    var name: ?[*:0]const u8 = undefined;
    const query = [_]TagItem{
        .{ .tag = bsd.IFQ_Address, .data = @intFromPtr(&address) },
        .{ .tag = bsd.IFQ_NetMask, .data = @intFromPtr(&netmask) },
        .{ .tag = bsd.IFQ_Gateway, .data = @intFromPtr(&gateway) },
        .{ .tag = bsd.IFQ_MTU, .data = @intFromPtr(&mtu) },
        .{ .tag = bsd.IFQ_State, .data = @intFromPtr(&state) },
        .{ .tag = bsd.IFQ_HardwareAddress, .data = @intFromPtr(&hardware) },
        .{ .tag = bsd.IFQ_DeviceName, .data = @intFromPtr(&name) },
        .{},
    };
    try testing.expectEqual(@as(i32, 0), sb.QueryInterfaceTagList("eth0", &query));
    try testing.expectEqual(sb.Inet_Addr("192.168.1.20"), address);
    try testing.expectEqual(sb.Inet_Addr("255.255.255.0"), netmask);
    try testing.expectEqual(@as(u32, 0), gateway);
    try testing.expectEqual(@as(u32, 1500), mtu);
    try testing.expectEqual(bsd.IFSTATE_UP, state);
    try testing.expectEqual([6]u8{ 2, 0, 0, 0, 0, 7 }, hardware);
    try testing.expectEqual(@as(?[*:0]const u8, null), name);
    try testing.expectEqual(@as(i32, -1), sb.QueryInterfaceTagList("eth9", &query));
    try testing.expectEqual(bsd.ENXIO, sb.Errno());

    const change = [_]TagItem{
        .{ .tag = bsd.IFA_Address, .data = sb.Inet_Addr("10.1.0.5") },
        .{ .tag = bsd.IFA_NetMask, .data = sb.Inet_Addr("255.255.0.0") },
        .{ .tag = bsd.IFA_Gateway, .data = sb.Inet_Addr("10.1.0.1") },
        .{ .tag = bsd.IFA_MTU, .data = 9000 },
        .{},
    };
    try testing.expectEqual(@as(i32, 0), sb.ConfigureInterfaceTagList("eth0", &change));
    try testing.expectEqual(@as(i32, 0), sb.QueryInterfaceTagList("eth0", &query));
    try testing.expectEqual(sb.Inet_Addr("10.1.0.5"), address);
    try testing.expectEqual(sb.Inet_Addr("10.1.0.1"), gateway);
    try testing.expectEqual(@as(u32, 1500), mtu);
    // The old net has no route any more; the new one and the default have.
    try testing.expect(_route.lookup(rig.stack, 0xC0A8_0101) != null);
    try testing.expectEqual(bsd.htonl(0x0A01_0001), bsd.htonl(_route.lookup(rig.stack, 0xC0A8_0101).?.next_hop));
    try testing.expectEqual(@as(u32, 0x0A01_0007), _route.lookup(rig.stack, 0x0A01_0007).?.next_hop);
    // A gateway on no interface's net is refused.
    const far = [_]TagItem{ .{ .tag = bsd.IFA_Gateway, .data = sb.Inet_Addr("172.16.0.1") }, .{} };
    try testing.expectEqual(@as(i32, -1), sb.ConfigureInterfaceTagList("eth0", &far));
    try testing.expectEqual(@as(i32, -1), sb.ConfigureInterfaceTagList("lo0", &change));
    try rig.deinit();
}

test "an interface taken down and up again, and its ARP entries told of" {
    var rig = try Rig.init();
    const sb = rig.sb;
    const down = [_]TagItem{ .{ .tag = bsd.IFA_State, .data = 0 }, .{} };
    const up = [_]TagItem{ .{ .tag = bsd.IFA_State, .data = bsd.IFSTATE_UP }, .{} };
    var state: u32 = 0;
    const query = [_]TagItem{ .{ .tag = bsd.IFQ_State, .data = @intFromPtr(&state) }, .{} };
    try testing.expectEqual(@as(i32, 0), sb.ConfigureInterfaceTagList("eth0", &down));
    try testing.expectEqual(@as(i32, 0), sb.QueryInterfaceTagList("eth0", &query));
    try testing.expectEqual(@as(u32, 0), state & bsd.IFSTATE_UP);
    // Down: no route goes through it, and it keeps its address.
    try testing.expectEqual(@as(?_route.Hop, null), _route.lookup(rig.stack, 0xC0A8_0101));
    try testing.expectEqual(@as(u32, 0xC0A8_0114), rig.stack.interfaces[1].address);
    try testing.expectEqual(@as(i32, 0), sb.ConfigureInterfaceTagList("eth0", &up));
    try testing.expect(_route.lookup(rig.stack, 0xC0A8_0101) != null);

    // An address asked for is in the cache, pending.
    const frame = rig.stack.frames.take(rig.stack.sys_base).?;
    _ = _netif.output(rig.stack, _netif.named(rig.stack, "eth0").?, frame, 0xC0A8_0101);
    var entries: [2]bsd.ArpInfo = undefined;
    try testing.expectEqual(@as(i32, 1), sb.GetNetworkStatistics(bsd.NETSTATUS_ARP, &entries, @sizeOf(@TypeOf(entries))));
    try testing.expectEqual(bsd.htonl(0xC0A8_0101), entries[0].address);
    try testing.expectEqual(bsd.ARPSTATE_PENDING, entries[0].state);
    try testing.expectEqualStrings("eth0", std.mem.sliceTo(&entries[0].interface, 0));
    try rig.deinit();
}

test "the list of interfaces, routes by hand, and name servers" {
    var rig = try Rig.init();
    const sb = rig.sb;
    const list = sb.ObtainInterfaceList().?;
    var names: [4][]const u8 = undefined;
    var count: usize = 0;
    var it = list.iterator();
    while (it.next()) |node| : (count += 1) names[count] = std.mem.span(node.name.?);
    sb.ReleaseInterfaceList(list);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings("lo0", names[0]);
    try testing.expectEqualStrings("eth0", names[1]);

    const route = [_]TagItem{
        .{ .tag = bsd.RTA_Destination, .data = sb.Inet_Addr("10.9.0.0") },
        .{ .tag = bsd.RTA_NetMask, .data = sb.Inet_Addr("255.255.0.0") },
        .{ .tag = bsd.RTA_Gateway, .data = sb.Inet_Addr("192.168.1.254") },
        .{},
    };
    try testing.expectEqual(@as(i32, 0), sb.AddRouteTagList(&route));
    try testing.expectEqual(@as(u32, 0xC0A8_01FE), _route.lookup(rig.stack, 0x0A09_0304).?.next_hop);
    try testing.expectEqual(@as(?_route.Hop, null), _route.lookup(rig.stack, 0x0B00_0001));
    const default = [_]TagItem{ .{ .tag = bsd.RTA_DefaultGateway, .data = sb.Inet_Addr("192.168.1.1") }, .{} };
    try testing.expectEqual(@as(i32, 0), sb.AddRouteTagList(&default));
    try testing.expectEqual(@as(u32, 0xC0A8_0101), _route.lookup(rig.stack, 0x0B00_0001).?.next_hop);
    try testing.expectEqual(@as(i32, 0), sb.DeleteRouteTagList(&route));
    try testing.expectEqual(@as(i32, -1), sb.DeleteRouteTagList(&route));
    try testing.expectEqual(bsd.ENXIO, sb.Errno());
    try testing.expectEqual(@as(i32, 0), sb.DeleteRouteTagList(&default));
    try testing.expectEqual(@as(?_route.Hop, null), _route.lookup(rig.stack, 0x0B00_0001));
    const nowhere = [_]TagItem{ .{ .tag = bsd.RTA_DefaultGateway, .data = sb.Inet_Addr("172.16.0.1") }, .{} };
    try testing.expectEqual(@as(i32, -1), sb.AddRouteTagList(&nowhere));
    try testing.expectEqual(bsd.ENETUNREACH, sb.Errno());

    for ([_][*:0]const u8{ "10.0.0.1", "10.0.0.2", "10.0.0.2", "10.0.0.3", "10.0.0.4" }) |server| {
        try testing.expectEqual(@as(i32, 0), sb.AddDomainNameServer(sb.Inet_Addr(server)));
    }
    try testing.expectEqual(@as(i32, -1), sb.AddDomainNameServer(sb.Inet_Addr("10.0.0.5")));
    try testing.expectEqual(bsd.ENOBUFS, sb.Errno());
    try testing.expectEqual(@as(i32, 0), sb.RemoveDomainNameServer(sb.Inet_Addr("10.0.0.2")));
    try testing.expectEqualSlices(u32, &.{ 0x0A00_0001, 0x0A00_0003, 0x0A00_0004 }, rig.stack.nameservers[0..rig.stack.nameserver_count]);
    try testing.expectEqual(@as(i32, -1), sb.RemoveDomainNameServer(sb.Inet_Addr("10.0.0.2")));
    try rig.deinit();
}
