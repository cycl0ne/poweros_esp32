// SPDX-License-Identifier: MIT
//! Host tests of filter.library: the rule language (addresses, every
//! keyword, the errors with their line and word), matching, the noted
//! exchanges and their time-outs - and the library on a stack, as
//! bsdsocket.library's packet hooks call it: two stacks on a wire the
//! test pumps, A at 10.0.0.1 and B at 10.0.0.2, B filtered.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const filter = sdk.filter;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const FilterBase = sdk.interface.filter.FilterBase;
const _rules = @import("../rules/_rules.zig");
const RuleSet = _rules.RuleSet;
const parse = @import("../rules/parse.zig");
const address = @import("../rules/address.zig");
const match = @import("../rules/match.zig");
const _flows = @import("../flows/_flows.zig");
const filter_init = @import("../filter_init.zig");
const filter_base = @import("../filter_base.zig");
const bsdsocket = @import("../../bsdsocket/bsdsocket_init.zig");
const _base = @import("../../bsdsocket/bsdsocket_base.zig");
const StackBase = _base.StackBase;
const Frame = @import("../../bsdsocket/frame/_frame.zig").Frame;
const _netif = @import("../../bsdsocket/netif/_netif.zig");
const Interface = _netif.Interface;
const _route = @import("../../bsdsocket/route/_route.zig");
const _ip = @import("../../bsdsocket/ip/_ip.zig");
const _timer = @import("../../bsdsocket/timer/_timer.zig");
const _tcp = @import("../../bsdsocket/tcp/_tcp.zig");
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;

const testing = std.testing;

// --- the rules alone ----------------------------------------------------------------

/// A rule set parsed from `text` in `memory`: the set, or the error.
fn parsed(text: []const u8, room_bytes: []align(8) u8, err: *filter.FilterError) ?*RuleSet {
    const room = parse.lines(text);
    const set = RuleSet.make(room_bytes[0..RuleSet.bytesFor(room, room)], room, room);
    if (parse.parse(text, set, err) != filter.FILTERERR_OK) return null;
    return set;
}

var set_bytes: [64 * 1024]u8 align(8) = undefined;

test "addresses: IPv4's parts, IPv6's groups with one ::, and IPv4 at IPv6's end" {
    const four = address.parse("192.168.1.20").?;
    try testing.expectEqual(bsd.AF_INET, four.family);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 192, 168, 1, 20 }, &four.bytes);
    const six = address.parse("fd00::1").?;
    try testing.expectEqual(bsd.AF_INET6, six.family);
    try testing.expectEqualSlices(u8, &.{ 0xFD, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, &six.bytes);
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0)), &address.parse("::").?.bytes);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8 }, &address.parse("1:2:3:4:5:6:7:8").?.bytes);
    const mapped = address.parse("::ffff:10.0.0.1").?;
    try testing.expectEqual(bsd.AF_INET, mapped.family);
    try testing.expectEqual(@as(u8, 10), mapped.bytes[12]);
    for ([_][]const u8{ "256.1.1.1", "1.2.3", "1.2.3.4.5", "1::2::3", ":1", "1:", "12345::", "g::1", "1.2.3.4x", "", "1:2:3:4:5:6:7:8:9" }) |bad| {
        if (address.parse(bad) != null) {
            std.debug.print("taken: {s}\n", .{bad});
            return error.TakenWrongly;
        }
    }
}

test "the rule language: an example file, every keyword, and what it makes" {
    const text =
        \\# a comment line
        \\default in on WLAN0 block   # one per interface
        \\
        \\pass in on wlan0 proto tcp from 192.168.1.0/24 to port 23
        \\pass in proto icmp type echo
        \\refuse in on eth0 proto udp to port 161-162
        \\block in from fd00::/8
        \\pass in inet6 proto icmp6 type 135
        \\PASS IN FLAGS S TO ANY PORT 80
        \\default in refuse
    ;
    var err: filter.FilterError = .{};
    const set = parsed(text, &set_bytes, &err) orelse {
        std.debug.print("line {d} column {d}: {s}\n", .{ err.line, err.column, std.mem.sliceTo(&err.word, 0) });
        return error.NotParsed;
    };
    try testing.expectEqual(@as(u32, 6), set.rule_count);
    try testing.expectEqual(@as(u32, 2), set.default_count);
    const rules = set.rules();
    const defaults = set.defaults();
    try testing.expectEqualStrings("wlan0", std.mem.sliceTo(&defaults[0].interface, 0));
    try testing.expectEqual(_rules.Action.block, defaults[0].action);
    try testing.expectEqual(@as(u32, 2), defaults[0].line);
    try testing.expectEqualStrings("default in on WLAN0 block", std.mem.sliceTo(&defaults[0].text, 0));
    try testing.expectEqual(@as(u8, 0), defaults[1].interface[0]);
    try testing.expectEqual(_rules.Action.refuse, defaults[1].action);

    const telnet = &rules[0];
    try testing.expectEqual(_rules.Action.pass, telnet.action);
    try testing.expectEqualStrings("wlan0", std.mem.sliceTo(&telnet.interface, 0));
    try testing.expectEqual(@as(u8, @intCast(bsd.IPPROTO_TCP)), telnet.protocol);
    try testing.expectEqual(bsd.AF_INET, telnet.family);
    try testing.expectEqual(@as(u8, 96 + 24), telnet.from.prefix);
    try testing.expectEqual(@as(u16, 23), telnet.to.low_port);
    try testing.expectEqual(@as(u16, 23), telnet.to.high_port);
    try testing.expectEqual(@as(u32, 4), telnet.line);
    try testing.expectEqualStrings("pass in on wlan0 proto tcp from 192.168.1.0/24 to port 23", std.mem.sliceTo(&telnet.text, 0));
    try testing.expectEqual(_rules.TypeMatch.echo, rules[1].type_match);
    try testing.expectEqual(@as(u16, 161), rules[2].to.low_port);
    try testing.expectEqual(@as(u16, 162), rules[2].to.high_port);
    try testing.expectEqual(bsd.AF_INET6, rules[3].family);
    try testing.expectEqual(@as(u8, 8), rules[3].from.prefix);
    try testing.expectEqual(@as(u8, 135), rules[4].type_number);
    // flags S makes it TCP's.
    try testing.expectEqual(@as(u8, 1), rules[5].syn_only);
    try testing.expectEqual(@as(u8, @intCast(bsd.IPPROTO_TCP)), rules[5].protocol);
    try testing.expectEqual(@as(u16, 80), rules[5].to.low_port);
}

test "the rule language: a bad word is said with its line and column, and nothing else counts" {
    const Bad = struct { text: []const u8, code: u32, line: u32, word: []const u8 };
    const cases = [_]Bad{
        .{ .text = "pass in\nallow in", .code = filter.FILTERERR_SYNTAX, .line = 2, .word = "allow" },
        .{ .text = "pass out proto tcp", .code = filter.FILTERERR_SYNTAX, .line = 1, .word = "out" },
        .{ .text = "pass in proto sctp", .code = filter.FILTERERR_SYNTAX, .line = 1, .word = "sctp" },
        .{ .text = "pass in from 10.0.0.0/33", .code = filter.FILTERERR_SYNTAX, .line = 1, .word = "10.0.0.0/33" },
        .{ .text = "pass in to port 70000", .code = filter.FILTERERR_SYNTAX, .line = 1, .word = "70000" },
        .{ .text = "pass in to port 9-1", .code = filter.FILTERERR_SYNTAX, .line = 1, .word = "9-1" },
        .{ .text = "pass in proto tcp proto udp", .code = filter.FILTERERR_TWICE, .line = 1, .word = "proto" },
        .{ .text = "default in on eth0 block\ndefault in on ETH0 pass", .code = filter.FILTERERR_TWICE, .line = 2, .word = "pass" },
        .{ .text = "pass in proto icmp to port 7", .code = filter.FILTERERR_SYNTAX, .line = 1, .word = "" },
        .{ .text = "pass in from 10.0.0.1 to fd00::1", .code = filter.FILTERERR_SYNTAX, .line = 1, .word = "" },
        .{ .text = "pass in inet6 proto icmp", .code = filter.FILTERERR_SYNTAX, .line = 1, .word = "" },
        .{ .text = "pass in on averyveryverylongname", .code = filter.FILTERERR_SYNTAX, .line = 1, .word = "averyveryverylongname" },
        .{ .text = "default in on eth0 block now", .code = filter.FILTERERR_SYNTAX, .line = 1, .word = "now" },
        .{ .text = "pass in flags SA", .code = filter.FILTERERR_SYNTAX, .line = 1, .word = "SA" },
    };
    for (cases) |case| {
        var err: filter.FilterError = .{};
        if (parsed(case.text, &set_bytes, &err) != null) {
            std.debug.print("taken: {s}\n", .{case.text});
            return error.TakenWrongly;
        }
        try testing.expectEqual(case.code, err.code);
        try testing.expectEqual(case.line, err.line);
        try testing.expectEqualStrings(case.word, std.mem.sliceTo(&err.word, 0));
    }
    var err: filter.FilterError = .{};
    _ = parsed("pass in on wlan0  bogus", &set_bytes, &err);
    try testing.expectEqual(@as(u32, 19), err.column);
}

fn viewOf(protocol: c_int, source: [16]u8, source_port: u16, destination: [16]u8, destination_port: u16) bsd.PacketView {
    var view: bsd.PacketView = .{
        .direction = bsd.PH_IN,
        .family = if (source[10] == 0xFF and source[0] == 0) bsd.AF_INET else bsd.AF_INET6,
        .protocol = @intCast(protocol),
        .source = .{ .s6_addr = source },
        .destination = .{ .s6_addr = destination },
        .source_port = source_port,
        .destination_port = destination_port,
    };
    @memcpy(view.interface[0..5], "wlan0");
    return view;
}

fn v4(text: []const u8) [16]u8 {
    return address.parse(text).?.bytes;
}

test "matching: the first rule that fits, nets by their prefix, ports, types, flags; then the default" {
    const text =
        \\default in on wlan0 block
        \\pass in on wlan0 proto tcp from 192.168.1.0/24 to port 23
        \\pass in proto icmp type echo
        \\refuse in proto udp to port 161-162
        \\pass in flags S to port 80
        \\block in from fd00::/8
    ;
    var err: filter.FilterError = .{};
    const set = parsed(text, &set_bytes, &err).?;
    var telnet = viewOf(bsd.IPPROTO_TCP, v4("192.168.1.7"), 40000, v4("192.168.1.2"), 23);
    try testing.expectEqual(@as(u32, 2), match.firstRule(set, &telnet).?.line);
    telnet.source = .{ .s6_addr = v4("192.168.2.7") };
    try testing.expect(match.firstRule(set, &telnet) == null);
    try testing.expectEqual(@as(u32, 1), match.defaultFor(set, &telnet).?.line);
    @memcpy(telnet.interface[0..5], "eth00");
    try testing.expect(match.defaultFor(set, &telnet) == null);

    var echo = viewOf(bsd.IPPROTO_ICMP, v4("10.0.0.9"), 0, v4("10.0.0.1"), 0);
    echo.icmp_type = 8;
    try testing.expectEqual(@as(u32, 3), match.firstRule(set, &echo).?.line);
    echo.icmp_type = 0;
    try testing.expect(match.firstRule(set, &echo) == null);

    const snmp = viewOf(bsd.IPPROTO_UDP, v4("10.0.0.9"), 5000, v4("10.0.0.1"), 162);
    try testing.expectEqual(_rules.Action.refuse, match.firstRule(set, &snmp).?.action);

    var web = viewOf(bsd.IPPROTO_TCP, v4("10.0.0.9"), 5000, v4("10.0.0.1"), 80);
    web.tcp_flags = bsd.TH_SYN;
    try testing.expectEqual(@as(u32, 5), match.firstRule(set, &web).?.line);
    web.tcp_flags = bsd.TH_SYN | bsd.TH_ACK;
    try testing.expect(match.firstRule(set, &web) == null);

    var ula = viewOf(bsd.IPPROTO_UDP, address.parse("fd12::5").?.bytes, 53, address.parse("fd12::1").?.bytes, 9999);
    ula.family = bsd.AF_INET6;
    try testing.expectEqual(@as(u32, 6), match.firstRule(set, &ula).?.line);
    ula.source = .{ .s6_addr = address.parse("2001:db8::5").?.bytes };
    try testing.expect(match.firstRule(set, &ula) == null);
}

test "exchanges: a datagram's and an echo's answers pass, the wrong one does not, and time ends them" {
    var table: _flows.Table = .{};
    // DNS: out from 10.0.0.1:40000 to 10.0.0.53:53.
    var question = viewOf(bsd.IPPROTO_UDP, v4("10.0.0.1"), 40000, v4("10.0.0.53"), 53);
    question.direction = bsd.PH_OUT;
    table.note(&question, 1_000_000);
    const answer = viewOf(bsd.IPPROTO_UDP, v4("10.0.0.53"), 53, v4("10.0.0.1"), 40000);
    try testing.expect(table.answers(&answer, 2_000_000));
    const elsewhere = viewOf(bsd.IPPROTO_UDP, v4("10.0.0.54"), 53, v4("10.0.0.1"), 40000);
    try testing.expect(!table.answers(&elsewhere, 2_000_000));
    // Kept alive by the answer at 2 s: still there at 61 s, gone at 63.
    try testing.expect(table.answers(&answer, 61_000_000));
    try testing.expect(!table.answers(&answer, 122_000_000));

    // An echo, its identifier 0x1234.
    var echo_bytes = [_]u8{ 8, 0, 0, 0, 0x12, 0x34, 0, 1 };
    var echo = viewOf(bsd.IPPROTO_ICMP, v4("10.0.0.1"), 0, v4("10.0.0.9"), 0);
    echo.direction = bsd.PH_OUT;
    echo.icmp_type = 8;
    echo.data = &echo_bytes;
    echo.length = echo_bytes.len;
    table.note(&echo, 200_000_000);
    var reply_bytes = [_]u8{ 0, 0, 0, 0, 0x12, 0x34, 0, 1 };
    var reply = viewOf(bsd.IPPROTO_ICMP, v4("10.0.0.9"), 0, v4("10.0.0.1"), 0);
    reply.icmp_type = 0;
    reply.data = &reply_bytes;
    reply.length = reply_bytes.len;
    var listed: [4]filter.FilterFlowInfo = undefined;
    try testing.expectEqual(@as(u32, 1), table.list(&listed, 201_000_000));
    try testing.expectEqual(@as(u16, 0x1234), listed[0].local_port);
    try testing.expectEqual(@as(u32, 1000), listed[0].idle_ms);
    try testing.expect(table.answers(&reply, 205_000_000));
    reply_bytes[5] = 0x35;
    try testing.expect(!table.answers(&reply, 205_000_000));
    reply_bytes[5] = 0x34;
    try testing.expect(!table.answers(&reply, 216_000_000));

    // Full: the one quiet longest makes room.
    for (0.._flows.slots) |index| {
        question.source_port = @intCast(1000 + index);
        table.note(&question, 300_000_000 + index);
    }
    question.source_port = 9;
    table.note(&question, 300_001_000);
    var first = answer;
    first.destination_port = 1000;
    try testing.expect(!table.answers(&first, 300_001_000));
    first.destination_port = 1001;
    try testing.expect(table.answers(&first, 300_001_000));
}

// --- the library on a stack -----------------------------------------------------------

var lent: [1024 * 1024]u8 align(16) = undefined;

const address_a: u32 = 0x0A00_0001;
const address_b: u32 = 0x0A00_0002;
const station: [6]u8 = .{ 2, 0, 0, 0, 0, 1 };

const Packet = struct {
    to_b: bool,
    length: usize,
    bytes: [1600]u8,
};

var wire: [64]Packet = undefined;
var wire_count: usize = 0;
var sent_by_b: usize = 0;

fn onto(to_b: bool, stack: *StackBase, frame: *Frame) i32 {
    const bytes = frame.bytes();
    wire[wire_count] = .{ .to_b = to_b, .length = bytes.len, .bytes = undefined };
    @memcpy(wire[wire_count].bytes[0..bytes.len], bytes);
    wire_count += 1;
    if (!to_b) sent_by_b += 1;
    stack.frames.give(stack.sys_base, frame);
    return 0;
}

fn fromA(stack: *StackBase, _: *Interface, frame: *Frame, _: *const [6]u8, _: u16) i32 {
    return onto(true, stack, frame);
}

fn fromB(stack: *StackBase, _: *Interface, frame: *Frame, _: *const [6]u8, _: u16) i32 {
    return onto(false, stack, frame);
}

/// A stack's own: its library, its interface on the wire, a base.
const Side = struct {
    lib: *exec.Library,
    stack: *StackBase,
    interface: *Interface,
    sb: *SocketBase,
};

const Rig = struct {
    kub: *utility_library.UtilityBase,
    region: *exec.MemHeader,
    /// A, off exec's list; B on it, as bsdsocket.library is to whoever
    /// opens it by name - filter.library among them.
    a: Side,
    b: Side,
    filter_lib: *exec.Library,
    fb: *FilterBase,

    fn init() !Rig {
        const kub = try utility_library.setUp();
        const sys = kexec.SysBase.iface();
        const region = sys.AddMemList(lent.len, exec.MEMF_ANY, 0, &lent, "lent").?;
        wire_count = 0;
        sent_by_b = 0;
        const table: *const exec.InitTable = @ptrCast(@alignCast(bsdsocket.bsdsocket_library_tag.init.?));
        const a_lib = sys.MakeLibrary(table.vectors, table.vector_count, table.data_size, table.init, null) orelse return error.NoStack;
        const a = try side(a_lib, address_a, &fromA, "eth0");
        const made = kexec.InitResident(kexec.SysBase, &bsdsocket.bsdsocket_library_tag, null) orelse return error.NoStack;
        const b = try side(@ptrCast(@alignCast(made)), address_b, &fromB, "eth0");
        const filter_made = kexec.InitResident(kexec.SysBase, &filter_init.filter_library_tag, null) orelse return error.NoFilter;
        const fb: *FilterBase = @ptrCast(sys.OpenLibrary(filter.FILTERNAME, 1) orelse return error.NoFilter);
        filter_base.filterBase(fb.lib()).fixed_time = 1_000_000;
        return .{ .kub = kub, .region = region, .a = a, .b = b, .filter_lib = @ptrCast(@alignCast(filter_made)), .fb = fb };
    }

    fn side(lib: *exec.Library, address_own: u32, transmit: _netif.TransmitFn, name: []const u8) !Side {
        const stack = _base.stackBase(lib);
        stack.no_task = 1;
        stack.fixed_time = 1_000_000;
        const interface = _netif.free(stack).?;
        interface.* = .{
            .address = address_own,
            .netmask = 0xFFFF_FF00,
            .broadcast = address_own | 0xFF,
            .mtu = 1500,
            .used = 1,
            .up = 1,
            .no_arp = 1,
            .transmit = transmit,
        };
        @memcpy(interface.name[0..name.len], name);
        _ = _route.add(stack, address_own, 0xFFFF_FF00, 0, interface);
        const opened = lib.vector(exec.OpenFn, exec.LIB_OPEN)(lib, 1) orelse return error.NoBase;
        return .{ .lib = lib, .stack = stack, .interface = interface, .sb = @ptrCast(opened) };
    }

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

    fn advance(rig: *Rig, now: u64) void {
        rig.a.stack.fixed_time = now;
        rig.b.stack.fixed_time = now;
        filter_base.filterBase(rig.fb.lib()).fixed_time = now;
        _timer.run(rig.a.stack, now);
        _timer.run(rig.b.stack, now);
    }

    fn load(rig: *Rig, text: []const u8) !void {
        var err: filter.FilterError = .{};
        const code = rig.fb.LoadFilterRules(text.ptr, @intCast(text.len), &err);
        if (code != filter.FILTERERR_OK) {
            std.debug.print("line {d}: {s}\n", .{ err.line, std.mem.sliceTo(&err.word, 0) });
            return error.NotLoaded;
        }
    }

    fn deinit(rig: *Rig) !void {
        const sys = kexec.SysBase.iface();
        rig.fb.ClearFilterRules();
        sys.CloseLibrary(rig.fb.lib());
        try testing.expect(sys.RemLibrary(rig.filter_lib) == null);
        sys.CloseLibrary(rig.a.sb.lib());
        _ = rig.a.lib.vector(exec.ExpungeFn, exec.LIB_EXPUNGE)(rig.a.lib);
        sys.CloseLibrary(rig.b.sb.lib());
        try testing.expect(rig.b.stack.hooks_in.isEmpty() and rig.b.stack.hooks_out.isEmpty());
        _ = sys.RemLibrary(rig.b.lib);
        try testing.expectEqual(@intFromPtr(rig.region.upper) - @intFromPtr(rig.region.lower), rig.region.free);
        sys.Remove(&rig.region.node);
        try utility_library.tearDown(rig.kub);
        kexec.deinit();
    }
};

fn at(address_own: u32, port: u16) bsd.sockaddr_in {
    return .{ .sin_port = bsd.htons(port), .sin_addr = .{ .s_addr = bsd.htonl(address_own) } };
}

fn socketOf(sb: *SocketBase, kind: i32) !i32 {
    const socket = sb.Socket(bsd.PF_INET, kind, 0);
    if (socket < 0) return error.NoSocket;
    var never: i32 = 1;
    _ = sb.IoctlSocket(socket, bsd.FIONBIO, &never);
    return socket;
}

/// A's connect to B's `port`, pumped: its pending error after, 0 while it
/// waits or once it is connected.
fn connectTo(rig: *Rig, client: i32, port: u16) !i32 {
    const a = rig.a.sb;
    var there = at(address_b, port);
    try testing.expectEqual(@as(i32, -1), a.Connect(client, there.anyConst(), @sizeOf(bsd.sockaddr_in)));
    rig.pump();
    var pending: i32 = 0;
    var size: u32 = @sizeOf(i32);
    _ = a.GetSockOpt(client, bsd.SOL_SOCKET, bsd.SO_ERROR, &pending, &size);
    return pending;
}

test "the library on a stack: closed but for port 23, answers to its own questions, counts, cleared" {
    var rig = try Rig.init();
    const a = rig.a.sb;
    const b = rig.b.sb;
    try rig.load(
        \\default in on eth0 block
        \\pass in proto tcp to port 23
        \\refuse in proto tcp to port 25
    );
    var listeners: [3]i32 = undefined;
    for (&listeners, [_]u16{ 23, 25, 80 }) |*listener, port| {
        listener.* = try socketOf(b, bsd.SOCK_STREAM);
        var here = at(address_b, port);
        try testing.expectEqual(@as(i32, 0), b.Bind(listener.*, here.anyConst(), @sizeOf(bsd.sockaddr_in)));
        try testing.expectEqual(@as(i32, 0), b.Listen(listener.*, 4));
    }
    // 23 passes; 25 is refused; 80, under the default, is silent.
    const telnet = try socketOf(a, bsd.SOCK_STREAM);
    try testing.expectEqual(@as(i32, 0), try connectTo(&rig, telnet, 23));
    var peer: bsd.sockaddr_in = .{};
    var peer_length: u32 = @sizeOf(bsd.sockaddr_in);
    const server = b.Accept(listeners[0], peer.any(), &peer_length);
    try testing.expect(server >= 0);
    const mail = try socketOf(a, bsd.SOCK_STREAM);
    try testing.expectEqual(bsd.ECONNREFUSED, try connectTo(&rig, mail, 25));
    const sent_before = sent_by_b;
    const web = try socketOf(a, bsd.SOCK_STREAM);
    try testing.expectEqual(@as(i32, 0), try connectTo(&rig, web, 80));
    try testing.expectEqual(sent_before, sent_by_b);
    try testing.expectEqual(@as(i32, -1), b.Accept(listeners[2], peer.any(), &peer_length));

    // The connection on 23 goes on: its segments are the stack's.
    try testing.expectEqual(@as(i32, 2), a.Send(telnet, "ls", 2, 0));
    rig.pump();
    var got: [16]u8 = undefined;
    try testing.expectEqual(@as(i32, 2), b.Recv(server, &got, got.len, 0));

    // B asks A a question over UDP: the answer comes in, though nothing
    // lets UDP in; a datagram nobody asked for does not.
    const asking = try socketOf(b, bsd.SOCK_DGRAM);
    var bound = at(address_b, 40000);
    try testing.expectEqual(@as(i32, 0), b.Bind(asking, bound.anyConst(), @sizeOf(bsd.sockaddr_in)));
    const answering = try socketOf(a, bsd.SOCK_DGRAM);
    var service = at(address_a, 53);
    try testing.expectEqual(@as(i32, 0), a.Bind(answering, service.anyConst(), @sizeOf(bsd.sockaddr_in)));
    try testing.expectEqual(@as(i32, 3), b.SendTo(asking, "who", 3, 0, service.anyConst(), @sizeOf(bsd.sockaddr_in)));
    rig.pump();
    var from: bsd.sockaddr_in = .{};
    var from_length: u32 = @sizeOf(bsd.sockaddr_in);
    try testing.expectEqual(@as(i32, 3), a.RecvFrom(answering, &got, got.len, 0, from.any(), &from_length));
    try testing.expectEqual(@as(i32, 2), a.SendTo(answering, "me", 2, 0, from.anyConst(), @sizeOf(bsd.sockaddr_in)));
    rig.pump();
    try testing.expectEqual(@as(i32, 2), b.Recv(asking, &got, got.len, 0));
    var flows: [4]filter.FilterFlowInfo = undefined;
    try testing.expectEqual(@as(u32, 1), rig.fb.GetFilterFlows(&flows, flows.len));
    try testing.expectEqual(@as(u16, 40000), flows[0].local_port);
    try testing.expectEqual(@as(u16, 53), flows[0].remote_port);
    const stranger = try socketOf(a, bsd.SOCK_DGRAM);
    try testing.expectEqual(@as(i32, 3), a.SendTo(stranger, "hey", 3, 0, bound.anyConst(), @sizeOf(bsd.sockaddr_in)));
    rig.pump();
    try testing.expectEqual(@as(i32, -1), b.Recv(asking, &got, got.len, 0));
    // A minute and more later, the answer is a stranger too.
    rig.advance(70_000_000);
    try testing.expectEqual(@as(i32, 2), a.SendTo(answering, "me", 2, 0, from.anyConst(), @sizeOf(bsd.sockaddr_in)));
    rig.pump();
    try testing.expectEqual(@as(i32, -1), b.Recv(asking, &got, got.len, 0));

    // The counts, in the file's order.
    var rules: [4]filter.FilterRuleInfo = undefined;
    try testing.expectEqual(@as(u32, 3), rig.fb.GetFilterRules(&rules, rules.len));
    try testing.expectEqual(filter.FILTERINFO_DEFAULT, rules[0].kind);
    try testing.expect(rules[0].hits >= 3);
    try testing.expectEqualStrings("pass in proto tcp to port 23", std.mem.sliceTo(&rules[1].text, 0));
    try testing.expectEqual(@as(u32, 1), rules[1].hits);
    try testing.expectEqual(@as(u32, 1), rules[2].hits);
    try testing.expectEqual(filter.FILTER_REFUSE, rules[2].action);
    try testing.expectEqual(rules[0].hits, rig.b.stack.counts.hook_dropped);

    // A bad file leaves the rules as they were.
    var err: filter.FilterError = .{};
    const bad = "pass in proto tcp to port 22\npass in sideways";
    try testing.expectEqual(filter.FILTERERR_SYNTAX, rig.fb.LoadFilterRules(bad, bad.len, &err));
    try testing.expectEqual(@as(u32, 2), err.line);
    try testing.expectEqual(@as(u32, 3), rig.fb.GetFilterRules(&rules, rules.len));

    // Cleared: everything passes, and the hooks are out.
    rig.fb.ClearFilterRules();
    try testing.expect(rig.b.stack.hooks_in.isEmpty());
    try testing.expectEqual(@as(u32, 0), rig.fb.GetFilterRules(&rules, rules.len));
    try testing.expectEqual(@as(i32, 3), a.SendTo(stranger, "hey", 3, 0, bound.anyConst(), @sizeOf(bsd.sockaddr_in)));
    rig.pump();
    try testing.expectEqual(@as(i32, 3), b.Recv(asking, &got, got.len, 0));

    for ([_]i32{ telnet, mail, web, answering, stranger }) |each| _ = a.CloseSocket(each);
    for ([_]i32{ server, asking, listeners[0], listeners[1], listeners[2] }) |each| _ = b.CloseSocket(each);
    rig.pump();
    rig.advance(70_000_000 + 2 * _tcp.msl_us);
    rig.pump();
    try rig.deinit();
}
