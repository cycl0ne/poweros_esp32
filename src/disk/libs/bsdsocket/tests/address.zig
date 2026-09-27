// SPDX-License-Identifier: MIT
//! Host tests of the stack's address type and its text (`ip6/address.zig`):
//! RFC 5952's own examples of how an address is written, the forms RFC 4291
//! lets a reader take, the ones it must refuse, and IPv4 mapped in and out.

const std = @import("std");
const address_file = @import("../ip6/address.zig");
const Address = address_file.Address;

const testing = std.testing;

fn written(text: []const u8) ![]const u8 {
    const address = address_file.parse(text) orelse return error.Unparsed;
    const Holder = struct {
        var buffer: [address_file.text_max]u8 = undefined;
    };
    const length = address_file.format(address, &Holder.buffer);
    return Holder.buffer[0..length];
}

test "addresses are written as RFC 5952 says" {
    // 4.1: no leading zeros; 4.2.1-4.2.3: the longest run of two or more
    // zero groups is ::, the first of runs equally long, and one zero group
    // is not; 4.3: lower case; 5: a mapped IPv4 address dotted.
    try testing.expectEqualStrings("2001:db8::1", try written("2001:0db8::0001"));
    try testing.expectEqualStrings("2001:db8::2:1", try written("2001:db8:0:0:0:0:2:1"));
    try testing.expectEqualStrings("2001:db8:0:1:1:1:1:1", try written("2001:db8:0:1:1:1:1:1"));
    try testing.expectEqualStrings("2001:db8::1:0:0:1", try written("2001:db8:0:0:1:0:0:1"));
    try testing.expectEqualStrings("2001:db8:0:0:1::", try written("2001:db8:0:0:1:0:0:0"));
    try testing.expectEqualStrings("2001:db8::abcd", try written("2001:DB8::ABCD"));
    try testing.expectEqualStrings("::", try written("0:0:0:0:0:0:0:0"));
    try testing.expectEqualStrings("::1", try written("0:0:0:0:0:0:0:1"));
    try testing.expectEqualStrings("fe80::1", try written("fe80:0:0:0:0:0:0:1"));
    try testing.expectEqualStrings("ff02::1:ff00:1", try written("ff02::1:ff00:1"));
    try testing.expectEqualStrings("1::", try written("1:0:0:0:0:0:0:0"));
    try testing.expectEqualStrings("::ffff:10.0.2.15", try written("::ffff:a00:20f"));
    try testing.expectEqualStrings("::ffff:10.0.2.15", try written("::ffff:10.0.2.15"));
    try testing.expectEqualStrings("1:2:3:4:5:6:7:8", try written("1:2:3:4:5:6:7:8"));
}

test "every form RFC 4291 allows is read" {
    const want = address_file.parse("2001:db8:0:0:8:800:200c:417a").?;
    try testing.expect(want.eql(address_file.parse("2001:DB8:0:0:8:800:200C:417A").?));
    try testing.expect(want.eql(address_file.parse("2001:db8::8:800:200c:417a").?));
    try testing.expect(address_file.parse("::13.1.68.3").?.eql(address_file.parse("::d01:4403").?));
    try testing.expect(address_file.parse("::").?.eql(Address.any));
    try testing.expect(address_file.parse("::1").?.eql(Address.loopback));
    try testing.expect(address_file.parse("ff02::1").?.eql(Address.all_nodes));
}

test "what is no address is refused" {
    const bad = [_][]const u8{
        "",                  ":",                     ":1",            "1:",
        "1:::2",             "1::2::3",               "::1::",         "12345::",
        "1:2:3:4:5:6:7:8:9", "1:2:3:4::5:6:7:8",      "1:2:3:4:5:6:7", "g::1",
        "fe80::1%eth0",      "1.2.3.4",               "::1.2.3",       "::ffff:1.2.3.04",
        "::ffff:256.0.0.1",  "1:2:3:4:5:6:7:1.2.3.4",
    };
    for (bad) |text| {
        if (address_file.parse(text) != null) {
            std.debug.print("read, but is no address: '{s}'\n", .{text});
            return error.TestUnexpectedResult;
        }
    }
}

test "IPv4's dotted quad, read strictly" {
    try testing.expectEqual(@as(?u32, 0x0A00_020F), address_file.parseV4("10.0.2.15"));
    try testing.expectEqual(@as(?u32, 0), address_file.parseV4("0.0.0.0"));
    try testing.expectEqual(@as(?u32, 0xFFFF_FFFF), address_file.parseV4("255.255.255.255"));
    for ([_][]const u8{ "", "1.2.3", "1.2.3.4.", ".1.2.3.4", "256.1.1.1", "010.0.0.1", "1..2.3", "1.2.3.a", "0x1.2.3.4" }) |text| {
        try testing.expectEqual(@as(?u32, null), address_file.parseV4(text));
    }
    var quad: [15]u8 = undefined;
    const length = address_file.formatV4(0xC0A8_01A3, &quad);
    try testing.expectEqualStrings("192.168.1.163", quad[0..length]);
}

test "IPv4 mapped in and out" {
    const mapped = Address.fromV4(0x0A00_020F);
    try testing.expect(mapped.isV4());
    try testing.expectEqual(@as(u32, 0x0A00_020F), mapped.v4());
    try testing.expect(mapped.eql(address_file.parse("::ffff:10.0.2.15").?));
    try testing.expect(!Address.loopback.isV4());
    try testing.expect(Address.fromV4(0).isUnspecified());
    try testing.expect(Address.any.isUnspecified());
    try testing.expect(!mapped.isUnspecified());
    try testing.expect(Address.fromV4(0x7F00_0001).isLoopback());
    try testing.expect(Address.loopback.isLoopback());
    try testing.expect(address_file.parse("fe80::1").?.isLinkLocal());
    try testing.expect(!address_file.parse("fec0::1").?.isLinkLocal());
    try testing.expect(Address.all_nodes.isMulticast());
}
