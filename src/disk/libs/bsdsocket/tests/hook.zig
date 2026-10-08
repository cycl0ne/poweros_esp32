// SPDX-License-Identifier: MIT
//! Host tests of the packet hooks (AddPacketHook): two stacks in one
//! process, A at 10.0.0.1 and B at 10.0.0.2, joined by a link that is the
//! test's own, as in tcp.zig. The test's hook records what it was shown
//! and answers what the test says: TCP and UDP passed, dropped and
//! refused, what a packet is for, the chain going out, priorities and
//! interfaces, taking a hook out, what never reaches a hook, and the
//! capture's copy of a packet stopped.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const utility = sdk.utility;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const bsdsocket = @import("../bsdsocket_init.zig");
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _route = @import("../route/_route.zig");
const _ip = @import("../ip/_ip.zig");
const _timer = @import("../timer/_timer.zig");
const _tcp = @import("../tcp/_tcp.zig");
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;

const testing = std.testing;

var lent: [1024 * 1024]u8 align(16) = undefined;

const address_a: u32 = 0x0A00_0001;
const address_b: u32 = 0x0A00_0002;
const station: [6]u8 = .{ 2, 0, 0, 0, 0, 1 };

// --- the wire -----------------------------------------------------------------------

const Packet = struct {
    to_b: bool,
    length: usize,
    bytes: [1600]u8,
};

var wire: [64]Packet = undefined;
var wire_count: usize = 0;
/// What each side put on the wire, all told.
var sent_by_a: usize = 0;
var sent_by_b: usize = 0;

fn onto(to_b: bool, stack: *StackBase, frame: *Frame) i32 {
    const bytes = frame.bytes();
    wire[wire_count] = .{ .to_b = to_b, .length = bytes.len, .bytes = undefined };
    @memcpy(wire[wire_count].bytes[0..bytes.len], bytes);
    wire_count += 1;
    if (to_b) sent_by_a += 1 else sent_by_b += 1;
    stack.frames.give(stack.sys_base, frame);
    return 0;
}

fn fromA(stack: *StackBase, _: *Interface, frame: *Frame, _: *const [6]u8, _: u16) i32 {
    return onto(true, stack, frame);
}

fn fromB(stack: *StackBase, _: *Interface, frame: *Frame, _: *const [6]u8, _: u16) i32 {
    return onto(false, stack, frame);
}

const Side = struct {
    lib: *exec.Library,
    stack: *StackBase,
    interface: *Interface,
    sb: *SocketBase,
};

const Rig = struct {
    kub: *utility_library.UtilityBase,
    region: *exec.MemHeader,
    a: Side,
    b: Side,

    fn init() !Rig {
        const kub = try utility_library.setUp();
        const sys = kexec.SysBase.iface();
        const region = sys.AddMemList(lent.len, exec.MEMF_ANY, 0, &lent, "lent").?;
        wire_count = 0;
        sent_by_a = 0;
        sent_by_b = 0;
        shown_count = 0;
        order_count = 0;
        answer = bsd.PACKET_PASS;
        return .{
            .kub = kub,
            .region = region,
            .a = try side(address_a, &fromA, "a0"),
            .b = try side(address_b, &fromB, "b0"),
        };
    }

    fn side(address: u32, transmit: _netif.TransmitFn, name: []const u8) !Side {
        const sys = kexec.SysBase.iface();
        const table: *const exec.InitTable = @ptrCast(@alignCast(bsdsocket.bsdsocket_library_tag.init.?));
        const lib = sys.MakeLibrary(table.vectors, table.vector_count, table.data_size, table.init, null) orelse return error.NoStack;
        const stack = _base.stackBase(lib);
        stack.no_task = 1;
        const interface = _netif.free(stack).?;
        interface.* = .{
            .address = address,
            .netmask = 0xFFFF_FF00,
            .broadcast = address | 0xFF,
            .mtu = 1500,
            .used = 1,
            .up = 1,
            .no_arp = 1,
            .transmit = transmit,
        };
        @memcpy(interface.name[0..name.len], name);
        _ = _route.add(stack, address, 0xFFFF_FF00, 0, interface);
        const opened = lib.vector(exec.OpenFn, exec.LIB_OPEN)(lib, 1) orelse return error.NoBase;
        return .{ .lib = lib, .stack = stack, .interface = interface, .sb = @ptrCast(opened) };
    }

    /// Everything on the wire delivered, and what that sends in turn.
    fn pump(rig: *Rig) void {
        var rounds: usize = 0;
        while (wire_count > 0 and rounds < 1000) : (rounds += 1) {
            const packet = wire[0];
            std.mem.copyForwards(Packet, wire[0 .. wire_count - 1], wire[1..wire_count]);
            wire_count -= 1;
            const target = if (packet.to_b) &rig.b else &rig.a;
            const frame = target.stack.frames.take(target.stack.sys_base).?;
            @memcpy(frame.room()[frame.start..][0..packet.length], packet.bytes[0..packet.length]);
            frame.length = @intCast(packet.length);
            _netif.receive(target.stack, target.interface, frame, &station, &station, _ip.ethertype, target.stack.fixed_time);
        }
    }

    /// Both stacks' clocks set to `now`, and their timers run.
    fn advance(rig: *Rig, now: u64) void {
        rig.a.stack.fixed_time = now;
        rig.b.stack.fixed_time = now;
        _timer.run(rig.a.stack, now);
        _timer.run(rig.b.stack, now);
    }

    fn deinit(rig: *Rig) !void {
        const sys = kexec.SysBase.iface();
        for ([_]*Side{ &rig.a, &rig.b }) |each| {
            sys.CloseLibrary(each.sb.lib());
            try testing.expect(each.stack.hooks_in.isEmpty() and each.stack.hooks_out.isEmpty());
            try testing.expectEqual(@as(u32, 0), each.stack.frames.used());
            try testing.expectEqual(@as(u16, 0), each.lib.open_cnt);
            _ = each.lib.vector(exec.ExpungeFn, exec.LIB_EXPUNGE)(each.lib);
        }
        try testing.expectEqual(@intFromPtr(rig.region.upper) - @intFromPtr(rig.region.lower), rig.region.free);
        sys.Remove(&rig.region.node);
        try utility_library.tearDown(rig.kub);
        kexec.deinit();
    }
};

// --- the test's hook ----------------------------------------------------------------

var shown: [32]bsd.PacketView = undefined;
var shown_count: usize = 0;
/// Which hook was called, in turn: each hook's `data` is its number.
var order: [16]usize = undefined;
var order_count: usize = 0;
var answer: u32 = bsd.PACKET_PASS;

fn record(hook: *utility.Hook, object: ?*anyopaque, _: ?*anyopaque) callconv(.c) usize {
    const view: *const bsd.PacketView = @ptrCast(@alignCast(object.?));
    if (shown_count < shown.len) {
        shown[shown_count] = view.*;
        shown_count += 1;
    }
    if (order_count < order.len) {
        order[order_count] = @intFromPtr(hook.data);
        order_count += 1;
    }
    return answer;
}

fn passing(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = record(hook, object, message);
    return bsd.PACKET_PASS;
}

fn last() *const bsd.PacketView {
    return &shown[shown_count - 1];
}

fn mapped(address: u32) [16]u8 {
    var bytes: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0, 0, 0, 0 };
    _ip.put32(&bytes, 12, address);
    return bytes;
}

fn at(address: u32, port: u16) bsd.sockaddr_in {
    return .{ .sin_port = bsd.htons(port), .sin_addr = .{ .s_addr = bsd.htonl(address) } };
}

fn socketOf(sb: *SocketBase, family: i32, kind: i32, protocol: i32) !i32 {
    const socket = sb.Socket(family, kind, protocol);
    if (socket < 0) return error.NoSocket;
    var never: i32 = 1;
    _ = sb.IoctlSocket(socket, bsd.FIONBIO, &never);
    return socket;
}

/// A's connect to B's `port`, pumped: its pending error after (0 while
/// it still waits, or connected).
fn connectAndPump(rig: *Rig, client: i32, port: u16) !i32 {
    const a = rig.a.sb;
    var there = at(address_b, port);
    try testing.expectEqual(@as(i32, -1), a.Connect(client, there.anyConst(), @sizeOf(bsd.sockaddr_in)));
    rig.pump();
    var pending: i32 = 0;
    var size: u32 = @sizeOf(i32);
    _ = a.GetSockOpt(client, bsd.SOL_SOCKET, bsd.SO_ERROR, &pending, &size);
    return pending;
}

// --- the tests ----------------------------------------------------------------------

test "a hook sees TCP with what it is for: a dropped SYN is silent, a refused one reset" {
    var rig = try Rig.init();
    const a = rig.a.sb;
    const b = rig.b.sb;
    var hook: utility.Hook = .{ .entry = &record };
    try testing.expectEqual(@as(i32, 0), b.AddPacketHook(&hook, null));
    // In no chain twice.
    try testing.expectEqual(@as(i32, -1), b.AddPacketHook(&hook, null));
    try testing.expectEqual(bsd.EINVAL, b.Errno());
    const listener = try socketOf(b, bsd.PF_INET, bsd.SOCK_STREAM, 0);
    var here = at(address_b, 23);
    try testing.expectEqual(@as(i32, 0), b.Bind(listener, here.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(@as(i32, 0), b.Listen(listener, 4));

    // Dropped: B says nothing.
    answer = bsd.PACKET_DROP;
    const first = try socketOf(a, bsd.PF_INET, bsd.SOCK_STREAM, 0);
    try testing.expectEqual(@as(i32, 0), try connectAndPump(&rig, first, 23));
    try testing.expectEqual(@as(usize, 0), sent_by_b);
    try testing.expectEqual(@as(u32, 1), rig.b.stack.counts.hook_dropped);
    const syn = last();
    try testing.expectEqual(bsd.PH_IN, @as(u32, syn.direction));
    try testing.expectEqual(bsd.AF_INET, syn.family);
    try testing.expectEqual(@as(u8, @intCast(bsd.IPPROTO_TCP)), syn.protocol);
    try testing.expectEqual(bsd.PACKET_BELONGS_LISTENER, syn.belongs);
    try testing.expectEqual(bsd.TH_SYN, syn.tcp_flags & (bsd.TH_SYN | bsd.TH_ACK));
    try testing.expectEqual(@as(u16, 23), syn.destination_port);
    try testing.expectEqualStrings("b0", std.mem.sliceTo(&syn.interface, 0));
    try testing.expectEqual(_netif.index(rig.b.stack, rig.b.interface), syn.interface_index);
    try testing.expectEqual(mapped(address_a), syn.source.s6_addr);
    try testing.expectEqual(mapped(address_b), syn.destination.s6_addr);
    try testing.expect(syn.length >= 20);
    _ = a.CloseSocket(first);

    // Refused: a reset, and the connect fails.
    answer = bsd.PACKET_REFUSE;
    const second = try socketOf(a, bsd.PF_INET, bsd.SOCK_STREAM, 0);
    try testing.expectEqual(bsd.ECONNREFUSED, try connectAndPump(&rig, second, 23));
    try testing.expectEqual(@as(u32, 1), rig.b.stack.counts.hook_refused);
    _ = a.CloseSocket(second);

    // Passed: it opens, and its segments are the connection's.
    answer = bsd.PACKET_PASS;
    const third = try socketOf(a, bsd.PF_INET, bsd.SOCK_STREAM, 0);
    try testing.expectEqual(@as(i32, 0), try connectAndPump(&rig, third, 23));
    var peer: bsd.sockaddr_in = .{};
    var peer_length: u32 = @sizeOf(bsd.sockaddr_in);
    const server = b.Accept(listener, peer.any(), &peer_length);
    try testing.expect(server >= 0);
    try testing.expectEqual(@as(i32, 5), a.Send(third, "hello", 5, 0));
    rig.pump();
    try testing.expectEqual(bsd.PACKET_BELONGS_CONNECTION, last().belongs);
    var got: [8]u8 = undefined;
    try testing.expectEqual(@as(i32, 5), b.Recv(server, &got, got.len, 0));

    // Nobody on the port, and dropped: not even the reset that says so.
    answer = bsd.PACKET_DROP;
    const sent_before = sent_by_b;
    const fourth = try socketOf(a, bsd.PF_INET, bsd.SOCK_STREAM, 0);
    try testing.expectEqual(@as(i32, 0), try connectAndPump(&rig, fourth, 99));
    try testing.expectEqual(sent_before, sent_by_b);
    try testing.expectEqual(bsd.PACKET_BELONGS_NONE, last().belongs);

    b.RemPacketHook(&hook);
    answer = bsd.PACKET_PASS;
    for ([_]i32{ third, fourth }) |each| _ = a.CloseSocket(each);
    for ([_]i32{ server, listener }) |each| _ = b.CloseSocket(each);
    rig.pump();
    // The connection's end waits out TIME_WAIT.
    rig.advance(2 * _tcp.msl_us);
    try rig.deinit();
}

test "UDP refused with an unreachable; the chain going out; priorities, interfaces, taking out, a closed base" {
    var rig = try Rig.init();
    const a = rig.a.sb;
    const b = rig.b.sb;
    const receiver = try socketOf(b, bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    var here = at(address_b, 5000);
    try testing.expectEqual(@as(i32, 0), b.Bind(receiver, here.anyConst(), @sizeOf(bsd.sockaddr_in)));
    const sender = try socketOf(a, bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    try testing.expectEqual(@as(i32, 0), a.Connect(sender, here.anyConst(), @sizeOf(bsd.sockaddr_in)));

    // Two hooks: the higher priority first; the lower one decides.
    var high: utility.Hook = .{ .entry = &passing, .data = @ptrFromInt(1) };
    var low: utility.Hook = .{ .entry = &record, .data = @ptrFromInt(2) };
    var elsewhere: utility.Hook = .{ .entry = &record, .data = @ptrFromInt(3) };
    try testing.expectEqual(@as(i32, 0), b.AddPacketHook(&low, &[_]utility.TagItem{ .{ .tag = bsd.PH_Priority, .data = @bitCast(@as(isize, -5)) }, .{} }));
    try testing.expectEqual(@as(i32, 0), b.AddPacketHook(&high, &[_]utility.TagItem{ .{ .tag = bsd.PH_Priority, .data = 10 }, .{} }));
    try testing.expectEqual(@as(i32, 0), b.AddPacketHook(&elsewhere, &[_]utility.TagItem{ .{ .tag = bsd.PH_Interface, .data = @intFromPtr("wlan0") }, .{} }));
    answer = bsd.PACKET_DROP;
    try testing.expectEqual(@as(i32, 3), a.Send(sender, "one", 3, 0));
    rig.pump();
    try testing.expectEqualSlices(usize, &.{ 1, 2 }, order[0..order_count]);
    try testing.expectEqual(bsd.PACKET_BELONGS_BOUND, last().belongs);
    try testing.expectEqual(@as(u16, 5000), last().destination_port);
    var got: [8]u8 = undefined;
    try testing.expectEqual(@as(i32, -1), b.Recv(receiver, &got, got.len, 0));
    try testing.expectEqual(bsd.EWOULDBLOCK, b.Errno());

    // Refused: the sender hears the port is unreachable.
    answer = bsd.PACKET_REFUSE;
    try testing.expectEqual(@as(i32, 3), a.Send(sender, "two", 3, 0));
    rig.pump();
    try testing.expectEqual(@as(i32, -1), a.Recv(sender, &got, got.len, 0));
    try testing.expectEqual(bsd.ECONNREFUSED, a.Errno());

    // Taken out: what comes now is B's socket's.
    b.RemPacketHook(&low);
    b.RemPacketHook(&high);
    b.RemPacketHook(&elsewhere);
    try testing.expect(rig.b.stack.hooks_in.isEmpty());
    try testing.expectEqual(@as(i32, 5), a.Send(sender, "three", 5, 0));
    rig.pump();
    try testing.expectEqual(@as(i32, 5), b.Recv(receiver, &got, got.len, 0));

    // Going out: A's own hook drops what it sends, and the send says so.
    order_count = 0;
    var outward: utility.Hook = .{ .entry = &record, .data = @ptrFromInt(4) };
    try testing.expectEqual(@as(i32, 0), a.AddPacketHook(&outward, &[_]utility.TagItem{ .{ .tag = bsd.PH_Direction, .data = bsd.PH_OUT }, .{} }));
    answer = bsd.PACKET_REFUSE;
    const sent_before = sent_by_a;
    try testing.expectEqual(@as(i32, -1), a.Send(sender, "four", 4, 0));
    try testing.expectEqual(bsd.EPERM, a.Errno());
    try testing.expectEqual(sent_before, sent_by_a);
    try testing.expectEqual(bsd.PH_OUT, @as(u32, last().direction));
    try testing.expectEqual(bsd.PACKET_BELONGS_NONE, last().belongs);
    try testing.expectEqual(@as(u16, 5000), last().destination_port);
    try testing.expectEqual(@as(u32, 1), rig.a.stack.counts.hook_dropped);

    // A base closed takes its hooks with it.
    const sys = kexec.SysBase.iface();
    const other: *SocketBase = @ptrCast(rig.b.lib.vector(exec.OpenFn, exec.LIB_OPEN)(rig.b.lib, 1).?);
    var its: utility.Hook = .{ .entry = &record };
    var kept: utility.Hook = .{ .entry = &record };
    try testing.expectEqual(@as(i32, 0), other.AddPacketHook(&its, null));
    try testing.expectEqual(@as(i32, 0), other.AddPacketHook(&kept, &[_]utility.TagItem{ .{ .tag = bsd.PH_Keep, .data = 1 }, .{} }));
    sys.CloseLibrary(other.lib());
    // The kept one stays, until any base takes it out.
    try testing.expect(!rig.b.stack.hooks_in.isEmpty());
    b.RemPacketHook(&kept);
    try testing.expect(rig.b.stack.hooks_in.isEmpty());

    answer = bsd.PACKET_PASS;
    _ = a.CloseSocket(sender);
    _ = b.CloseSocket(receiver);
    try rig.deinit();
}

test "never shown: ICMP's errors and lo0; a packet stopped is copied to a capture marked" {
    var rig = try Rig.init();
    const a = rig.a.sb;
    const b = rig.b.sb;
    // A drops everything that comes in; B has no socket on the port.
    var everything: utility.Hook = .{ .entry = &record };
    try testing.expectEqual(@as(i32, 0), a.AddPacketHook(&everything, null));
    answer = bsd.PACKET_DROP;
    const sender = try socketOf(a, bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    var nowhere = at(address_b, 7777);
    try testing.expectEqual(@as(i32, 0), a.Connect(sender, nowhere.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(@as(i32, 1), a.Send(sender, "x", 1, 0));
    rig.pump();
    // B's port unreachable reached A's socket all the same.
    var got: [64]u8 = undefined;
    try testing.expectEqual(@as(i32, -1), a.Recv(sender, &got, got.len, 0));
    try testing.expectEqual(bsd.ECONNREFUSED, a.Errno());
    try testing.expectEqual(@as(usize, 0), shown_count);
    // lo0 too.
    const local = try socketOf(a, bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    var loop = at(0x7F00_0001, 6000);
    try testing.expectEqual(@as(i32, 0), a.Bind(local, loop.anyConst(), @sizeOf(bsd.sockaddr_in)));
    const looped = try socketOf(a, bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    try testing.expectEqual(@as(i32, 2), a.SendTo(looped, "lo", 2, 0, loop.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(@as(i32, 2), a.Recv(local, &got, got.len, 0));
    try testing.expectEqual(@as(usize, 0), shown_count);

    // B watches its interface and drops a datagram: two copies, the frame
    // as it came and the packet stopped, marked.
    var dropping: utility.Hook = .{ .entry = &record };
    try testing.expectEqual(@as(i32, 0), b.AddPacketHook(&dropping, null));
    const capture = b.Socket(bsd.PF_PACKET, bsd.SOCK_RAW, 0);
    try testing.expect(capture >= 0);
    var never: i32 = 1;
    _ = b.IoctlSocket(capture, bsd.FIONBIO, &never);
    const receiver = try socketOf(b, bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    var port = at(address_b, 5353);
    try testing.expectEqual(@as(i32, 0), b.Bind(receiver, port.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(@as(i32, 3), a.SendTo(looped, "abc", 3, 0, port.anyConst(), @sizeOf(bsd.sockaddr_in)));
    rig.pump();
    const header_bytes = @sizeOf(bsd.CaptureHeader);
    var buffer: [1600]u8 = undefined;
    try testing.expectEqual(@as(i32, header_bytes + 14 + 20 + 8 + 3), b.Recv(capture, &buffer, buffer.len, 0));
    const seen: *align(1) const bsd.CaptureHeader = @ptrCast(&buffer);
    try testing.expectEqual(@as(u8, 0), seen.flags);
    try testing.expectEqual(bsd.CAPTURE_LINK_ETHERNET, seen.link);
    try testing.expectEqual(@as(i32, header_bytes + 4 + 20 + 8 + 3), b.Recv(capture, &buffer, buffer.len, 0));
    const stopped: *align(1) const bsd.CaptureHeader = @ptrCast(&buffer);
    try testing.expectEqual(bsd.CAPTURE_FILTERED, stopped.flags);
    try testing.expectEqual(bsd.CAPTURE_LINK_NULL, stopped.link);
    try testing.expectEqual(bsd.CAPTURE_IN, stopped.direction);
    const family: u32 = @bitCast(buffer[header_bytes..][0..4].*);
    try testing.expectEqual(@as(u32, bsd.AF_INET), family);
    try testing.expectEqual(@as(u8, 0x45), buffer[header_bytes + 4]);
    try testing.expectEqualStrings("abc", buffer[header_bytes + 4 + 20 + 8 ..][0..3]);

    answer = bsd.PACKET_PASS;
    for ([_]i32{ sender, local, looped }) |each| _ = a.CloseSocket(each);
    for ([_]i32{ capture, receiver }) |each| _ = b.CloseSocket(each);
    try rig.deinit();
}
