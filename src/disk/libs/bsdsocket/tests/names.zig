// SPDX-License-Identifier: MIT
//! Host tests of names: DNS questions and answers - honest ones and ones
//! written to hurt - the hosts file, the cache, and GetHostByName where no
//! network is needed.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const TagItem = sdk.utility.TagItem;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const bsdsocket = @import("../bsdsocket_init.zig");
const _base = @import("../bsdsocket_base.zig");
const _ip = @import("../ip/_ip.zig");
const dns = @import("../names/dns.zig");
const hosts = @import("../names/hosts.zig");
const _names = @import("../names/_names.zig");
const Address = @import("../ip6/address.zig").Address;
const parse = @import("../ip6/address.zig").parse;
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;

const testing = std.testing;

test "a question is labels, a type and a class" {
    var packet: [64]u8 = undefined;
    const length = dns.question(&packet, 0x1234, "www.example.org", dns.type_a);
    try testing.expectEqual(@as(usize, 12 + 17 + 4), length);
    try testing.expectEqual(@as(u16, 0x1234), _ip.get16(&packet, 0));
    try testing.expectEqualSlices(u8, "\x03www\x07example\x03org\x00", packet[12..29]);
    try testing.expectEqual(dns.question(&packet, 1, "example.org.", dns.type_a), dns.question(&packet, 1, "example.org", dns.type_a));
    try testing.expectEqual(@as(usize, 0), dns.question(&packet, 1, "a..b", dns.type_a));
    try testing.expectEqual(@as(usize, 0), dns.question(&packet, 1, "x" ** 64, dns.type_a));
}

/// An answer to question `id` for example.org: two A records, the second
/// name a pointer back to the question's.
fn exampleAnswer(into: []u8, id: u16) usize {
    const bytes = [_]u8{
        0x12, 0x34, 0x81, 0x80, 0,   1,    0,    2,   0,   0,    0,   0,
        7,    'e',  'x',  'a',  'm', 'p',  'l',  'e', 3,   'o',  'r', 'g',
        0,    0,    1,    0,    1,   0xC0, 12,   0,   1,   0,    1,   0,
        0,    0x0E, 0x10, 0,    4,   104,  20,   26,  136, 0xC0, 12,  0,
        1,    0,    1,    0,    0,   0x00, 0x3C, 0,   4,   172,  66,  157,
        237,
    };
    @memcpy(into[0..bytes.len], &bytes);
    _ip.put16(into, 0, id);
    return bytes.len;
}

test "an honest answer gives its addresses and the shortest time to live" {
    var packet: [128]u8 = undefined;
    const length = exampleAnswer(&packet, 0x4242);
    const found = dns.answer(packet[0..length], 0x4242, dns.type_a).?;
    try testing.expectEqual(@as(usize, 2), found.count);
    try testing.expect(found.addresses[0].eql(Address.fromV4(0x6814_1A88)));
    try testing.expect(found.addresses[1].eql(Address.fromV4(0xAC42_9DED)));
    try testing.expectEqual(@as(u32, 60), found.ttl);
    // Another id: not ours.
    try testing.expectEqual(@as(?dns.Answer, null), dns.answer(packet[0..length], 0x4243, dns.type_a));
    // A name error.
    packet[3] = 0x83;
    try testing.expectEqual(dns.rcode_name_error, dns.answer(packet[0..length], 0x4242, dns.type_a).?.rcode);
}

test "answers written to hurt are refused, and nothing is read past their end" {
    var packet: [128]u8 = undefined;
    var length = exampleAnswer(&packet, 7);
    // Every answer cut short, at every byte.
    var cut: usize = 12;
    while (cut < length) : (cut += 1) {
        if (dns.answer(packet[0..cut], 7, dns.type_a)) |partial| {
            try testing.expect(partial.count < 2);
        }
    }
    // A data length past the end.
    var bad = packet;
    _ip.put16(&bad, 29 + 10, 400);
    try testing.expectEqual(@as(?dns.Answer, null), dns.answer(bad[0..length], 7, dns.type_a));
    // A pointer that points at itself, and one past the end.
    bad = packet;
    bad[29] = 0xC0;
    bad[30] = 29;
    try testing.expectEqual(@as(?dns.Answer, null), dns.answer(bad[0..length], 7, dns.type_a));
    bad = packet;
    bad[30] = 200;
    try testing.expectEqual(@as(?dns.Answer, null), dns.answer(bad[0..length], 7, dns.type_a));
    // Two pointers pointing at each other.
    bad = packet;
    bad[12] = 0xC0;
    bad[13] = 14;
    bad[14] = 0xC0;
    bad[15] = 12;
    try testing.expectEqual(@as(?dns.Answer, null), dns.answer(bad[0..length], 7, dns.type_a));
    // Counts far larger than the packet.
    bad = packet;
    _ip.put16(&bad, 6, 0xFFFF);
    try testing.expectEqual(@as(?dns.Answer, null), dns.answer(bad[0..length], 7, dns.type_a));
    bad = packet;
    _ip.put16(&bad, 4, 0xFFFF);
    try testing.expectEqual(@as(?dns.Answer, null), dns.answer(bad[0..length], 7, dns.type_a));
    // A label length with its top bits half set.
    bad = packet;
    bad[12] = 0x47;
    try testing.expectEqual(@as(?dns.Answer, null), dns.answer(bad[0..length], 7, dns.type_a));
    // A name longer than 255 bytes in labels that each fit.
    var long: [400]u8 = @splat(0);
    @memcpy(long[0..12], packet[0..12]);
    _ip.put16(&long, 4, 1);
    _ip.put16(&long, 6, 0);
    var at: usize = 12;
    for (0..5) |_| {
        long[at] = 63;
        @memset(long[at + 1 ..][0..63], 'a');
        at += 64;
    }
    long[at] = 0;
    length = at + 5;
    try testing.expectEqual(@as(?dns.Answer, null), dns.answer(long[0..length], 7, dns.type_a));
}

test "a PTR answer gives its name" {
    const bytes = [_]u8{
        0,   9,   0x81, 0x80, 0,   0,   0,   1,   0,   0,   0,   0,
        1,   '2', 1,    '2',  1,   '0', 2,   '1', '0', 7,   'i', 'n',
        '-', 'a', 'd',  'd',  'r', 4,   'a', 'r', 'p', 'a', 0,   0,
        12,  0,   1,    0,    0,   0,   60,  0,   9,   7,   'g', 'a',
        't', 'e', 'w',  'a',  'y', 0,
    };
    const found = dns.answer(&bytes, 9, dns.type_ptr).?;
    try testing.expect(found.has_name);
    try testing.expectEqualStrings("gateway", std.mem.sliceTo(&found.name, 0));
}

test "the hosts file: names, aliases, comments, case, both families" {
    const text =
        \\# this machine's friends
        \\127.0.0.1   localhost
        \\192.168.1.10 printer Printer.home.lan  # the one upstairs
        \\fd00::10     printer
        \\bad.address nothing
        \\10.0.0.5
    ;
    const v4 = bsd.AF_INET;
    const v6 = bsd.AF_INET6;
    try testing.expect(hosts.find(text, "PRINTER.home.lan", v4).?.eql(Address.fromV4(0xC0A8_010A)));
    try testing.expect(hosts.find(text, "localhost", v4).?.eql(Address.fromV4(0x7F00_0001)));
    try testing.expect(hosts.find(text, "printer", v6).?.eql(parse("fd00::10").?));
    try testing.expect(hosts.find(text, "localhost", v6) == null);
    try testing.expect(hosts.find(text, "upstairs", v4) == null);
    try testing.expect(hosts.find(text, "nothing", v4) == null);
    try testing.expectEqualStrings("printer", hosts.reverse(text, Address.fromV4(0xC0A8_010A)).?);
    try testing.expectEqualStrings("printer", hosts.reverse(text, parse("fd00::10").?).?);
    try testing.expectEqual(@as(?[]const u8, null), hosts.reverse(text, Address.fromV4(0x0A00_0005)));
}

test "the cache keeps an answer for its time, within its bounds" {
    const kub = try utility_library.setUp();
    const made = kexec.InitResident(kexec.SysBase, &bsdsocket.bsdsocket_library_tag, null) orelse return error.NoLibrary;
    const lib: *exec.Library = @ptrCast(@alignCast(made));
    const stack = _base.stackBase(lib);
    var addresses: [_names.addresses_max]Address = undefined;
    const v4 = bsd.AF_INET;
    _names.remember(stack, "example.org", v4, &.{ Address.fromV4(1), Address.fromV4(2) }, 5, 0);
    try testing.expectEqual(@as(usize, 2), _names.cached(stack, "EXAMPLE.org", v4, 29_000_000, &addresses));
    // Not what IPv6 asks for.
    try testing.expectEqual(@as(usize, 0), _names.cached(stack, "example.org", bsd.AF_INET6, 29_000_000, &addresses));
    // Held to 30 s at the least.
    try testing.expectEqual(@as(usize, 0), _names.cached(stack, "example.org", v4, 30_000_000, &addresses));
    _names.remember(stack, "long.example", v4, &.{Address.fromV4(3)}, 999_999, 0);
    try testing.expectEqual(@as(usize, 1), _names.cached(stack, "long.example", v4, 3_599_000_000, &addresses));
    try testing.expectEqual(@as(usize, 0), _names.cached(stack, "long.example", v4, 3_600_000_000, &addresses));

    // GetHostByName without a network: dotted text, localhost, and no
    // name server to ask.
    const sys = kexec.SysBase.iface();
    const sb: *SocketBase = @ptrCast(sys.OpenLibrary(bsd.SOCKETNAME, 1).?);
    const host = sb.GetHostByName("10.1.2.3").?;
    try testing.expectEqual(bsd.htonl(0x0A01_0203), @as(*align(1) const u32, @ptrCast(host.h_addr_list.?[0].?)).*);
    try testing.expectEqual(@as(?[*]u8, null), host.h_addr_list.?[1]);
    try testing.expectEqualStrings("localhost", std.mem.span(sb.GetHostByName("localhost").?.h_name.?));
    try testing.expectEqual(@as(?*bsd.hostent, null), sb.GetHostByName("example.net"));
    var h_errno: u32 = 0;
    const tags = [_]TagItem{ .{ .tag = bsd.SBTM_GETREF(bsd.SBTC_HERRNO), .data = @intFromPtr(&h_errno) }, .{} };
    _ = sb.SocketBaseTagList(&tags);
    try testing.expectEqual(@as(u32, @bitCast(bsd.NO_RECOVERY)), h_errno);
    // Cached, it needs no server.
    _names.remember(stack, "cached.example", bsd.AF_INET, &.{Address.fromV4(0x0A00_0009)}, 60, 0);
    const cached_host = sb.GetHostByName("cached.example").?;
    try testing.expectEqual(bsd.htonl(0x0A00_0009), @as(*align(1) const u32, @ptrCast(cached_host.h_addr_list.?[0].?)).*);
    var name: [16]u8 = undefined;
    try testing.expectEqual(@as(i32, 0), sb.GetHostName(&name, name.len));
    try testing.expectEqualStrings("poweros", std.mem.sliceTo(&name, 0));
    try testing.expectEqual(@as(i32, 0), sb.SetHostName("bench"));
    try testing.expectEqual(@as(i32, 0), sb.GetHostName(&name, name.len));
    try testing.expectEqualStrings("bench", std.mem.sliceTo(&name, 0));
    try testing.expectEqual(@as(i32, -1), sb.GetHostName(&name, 3));
    sys.CloseLibrary(sb.lib());
    _ = sys.RemLibrary(lib);
    try utility_library.tearDown(kub);
    kexec.deinit();
}
