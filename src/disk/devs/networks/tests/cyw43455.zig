// SPDX-License-Identifier: MIT
//! Host tests of cyw43455.device: its NVRAM image - what Linux's
//! brcmfmac makes of a board's NVRAM file, its strings, the padding and
//! the length word - what it reads from the firmware: events, and a
//! scan's networks - and what it tells the firmware to join a network.
//! The chip itself is proved on the CM5.

const std = @import("std");
const sdk = @import("sdk");
const wireless = sdk.devices.wireless;
const firmware = @import("../cyw43455/firmware.zig");
const events = @import("../cyw43455/events.zig");
const scan = @import("../cyw43455/scan.zig");
const join = @import("../cyw43455/join.zig");
const nvramImage = firmware.nvramImage;

test "nvramImage: strings, comments, padding and the length word" {
    const text = "# a board\nsromrev=11\n  boardrev=0x1304\nbad line\nRAW1=x\nxtal=37400#crystal";
    var into: [128]u8 = undefined;
    const length = nvramImage(text, &into);
    const strings = "sromrev=11\x00boardrev=0x1304\x00xtal=37400\x00";
    try std.testing.expectEqualStrings(strings, into[0..strings.len]);
    // 38 bytes of strings and a NUL more, padded to 40: ten words.
    try std.testing.expectEqual(@as(usize, 44), length);
    try std.testing.expectEqual(@as(u32, 0xFFF5_000A), std.mem.readInt(u32, into[40..44], .little));
}

test "nvramImage: a board revision added when the file has none" {
    var into: [64]u8 = undefined;
    const length = nvramImage("a=1\n", &into);
    try std.testing.expectEqualStrings("a=1\x00boardrev=0xff\x00", into[0..18]);
    try std.testing.expectEqual(@as(usize, 24), length);
}

test "an event read from its frame's payload" {
    // BCDC's header, a word of the firmware's after it, then the packet.
    var payload: [4 + 4 + 72 + 3]u8 = @splat(0);
    payload[3] = 1;
    const packet = payload[8..];
    std.mem.writeInt(u16, packet[12..14], 0x886C, .big);
    packet[19..22].* = .{ 0x00, 0x10, 0x18 };
    std.mem.writeInt(u16, packet[22..24], 1, .big);
    const event = packet[24..72];
    std.mem.writeInt(u16, event[2..4], events.FLAG_LINK, .big);
    std.mem.writeInt(u32, event[4..8], events.E_LINK, .big);
    std.mem.writeInt(u32, event[8..12], events.STATUS_SUCCESS, .big);
    std.mem.writeInt(u32, event[20..24], 3, .big);
    event[24..30].* = .{ 1, 2, 3, 4, 5, 6 };
    packet[72..75].* = .{ 7, 8, 9 };
    const found = events.parse(events.packetOf(&payload).?).?;
    try std.testing.expectEqual(events.E_LINK, found.kind);
    try std.testing.expectEqual(events.FLAG_LINK, found.flags);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, &found.address);
    try std.testing.expectEqualSlices(u8, &.{ 7, 8, 9 }, found.data);
    // A data length past the packet is no event; nor is an IPv4 frame.
    std.mem.writeInt(u32, event[20..24], 4, .big);
    try std.testing.expect(events.parse(packet) == null);
    std.mem.writeInt(u16, packet[12..14], 0x0800, .big);
    try std.testing.expect(!events.isBroadcom(packet));
}

test "the escan request: every network, every channel, the firmware's times" {
    const params = scan.request(7);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, params[0..4], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, params[4..6], .little));
    try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, params[6..8], .little));
    try std.testing.expectEqualSlices(u8, &(.{0xFF} ** 6), params[8 + 36 ..][0..6]);
    try std.testing.expectEqual(@as(u8, 2), params[8 + 42]);
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, params[8 + 56 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, params[8 + 60 ..][0..4], .little));
}

/// A firmware record of an access point: `name`, `bssid`'s last byte,
/// its signal, its chanspec and control channel, and the elements after.
fn record(into: []u8, name: []const u8, last: u8, rssi: i16, chanspec: u16, control: u8, elements: []const u8) usize {
    const length = 128 + elements.len;
    @memset(into[0..length], 0);
    std.mem.writeInt(u32, into[4..8], @intCast(length), .little);
    into[8..14].* = .{ 2, 0, 0, 0, 0, last };
    std.mem.writeInt(u16, into[16..18], 0x0011, .little);
    into[18] = @intCast(name.len);
    @memcpy(into[19..][0..name.len], name);
    std.mem.writeInt(u16, into[72..74], chanspec, .little);
    std.mem.writeInt(i16, into[78..80], rssi, .little);
    into[88] = control;
    std.mem.writeInt(u16, into[116..118], 128, .little);
    std.mem.writeInt(u32, into[120..124], @intCast(elements.len), .little);
    @memcpy(into[128..][0..elements.len], elements);
    return length;
}

test "a scan's results: names, channels, signals, how each is joined" {
    const rsn = [_]u8{ 48, 20, 1, 0, 0x00, 0x0F, 0xAC, 4, 1, 0, 0x00, 0x0F, 0xAC, 4, 1, 0, 0x00, 0x0F, 0xAC, 8, 0x0C, 0 };
    var data: [12 + 2 * 160]u8 = @splat(0);
    std.mem.writeInt(u16, data[8..10], 3, .little);
    std.mem.writeInt(u16, data[10..12], 2, .little);
    var at: usize = 12;
    at += record(data[at..], "Home", 1, -48, 6, 6, &rsn);
    // 40 MHz around channel 38, the upper half: control channel 40.
    at += record(data[at..], "Cafe", 2, -71, 0x1800 | 1 << 8 | 38, 0, &.{});
    var heard: scan.Heard = .{};
    try std.testing.expectEqual(@as(?u16, 3), scan.results(data[0..at], &heard));
    try std.testing.expectEqual(@as(usize, 2), heard.count);
    const home = heard.strongest("Home").?;
    try std.testing.expectEqual(@as(u8, 6), home.channel);
    try std.testing.expectEqual(@as(i8, -48), home.rssi);
    try std.testing.expectEqual(wireless.S2AUTH_WPA3_PSK, home.authMode());
    try std.testing.expectEqual(wireless.S2ENC_CCMP, home.encryption());
    const cafe = heard.strongest("Cafe").?;
    try std.testing.expectEqual(@as(u8, 40), cafe.channel);
    try std.testing.expectEqual(wireless.S2AUTH_WEP, cafe.authMode());
}

test "a join's parameters: the name, Linux's times, the access point on its channel" {
    const bssid = [6]u8{ 0x9C, 0x05, 0xD6, 0x3C, 0xB7, 0x77 };
    const params = join.params("PowerOS test net", &bssid, 40);
    try std.testing.expectEqual(@as(usize, 70), params.len);
    try std.testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, params[0..4], .little));
    try std.testing.expectEqualStrings("PowerOS test net", params[4..20]);
    try std.testing.expectEqual(@as(u8, 0xFF), params[36]);
    try std.testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, params[40..44], .little));
    try std.testing.expectEqual(@as(u32, 320), std.mem.readInt(u32, params[44..48], .little));
    try std.testing.expectEqual(@as(u32, 400), std.mem.readInt(u32, params[48..52], .little));
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, params[52..56], .little));
    try std.testing.expectEqualSlices(u8, &bssid, params[56..62]);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, params[64..68], .little));
    // Channel 40 at 20 MHz in the 5 GHz band; channel 11 in the 2.4 GHz one.
    try std.testing.expectEqual(@as(u16, 0xD028), std.mem.readInt(u16, params[68..70], .little));
    try std.testing.expectEqual(@as(u16, 0x100B), join.chanspec(11));
}

test "a key for the firmware: the pairwise one for the access point, the group's with its counter" {
    const ap = [6]u8{ 0x9C, 0x05, 0xD6, 0x3C, 0xB7, 0x77 };
    const rsc = [8]u8{ 1, 2, 3, 4, 5, 6, 0, 0 };
    var bytes: [32]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @intCast(i);
    const pairwise = join.key(bytes[0..16], 0, join.ALGO_AES_CCM, &rsc, &ap);
    try std.testing.expectEqual(@as(usize, 164), pairwise.len);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, pairwise[0..4], .little));
    try std.testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, pairwise[4..8], .little));
    try std.testing.expectEqualSlices(u8, bytes[0..16], pairwise[8..24]);
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, pairwise[112..116], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, pairwise[116..120], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, pairwise[132..136], .little));
    try std.testing.expectEqualSlices(u8, &ap, pairwise[156..162]);
    // A TKIP group key: its MIC keys trade places, the counter goes in.
    const group = join.key(&bytes, 2, join.ALGO_TKIP, &rsc, null);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, group[0..4], .little));
    try std.testing.expectEqual(@as(u32, 32), std.mem.readInt(u32, group[4..8], .little));
    try std.testing.expectEqualSlices(u8, bytes[0..16], group[8..24]);
    try std.testing.expectEqualSlices(u8, bytes[24..32], group[24..32]);
    try std.testing.expectEqualSlices(u8, bytes[16..24], group[32..40]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, group[112..116], .little));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, group[116..120], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, group[132..136], .little));
    try std.testing.expectEqual(@as(u32, 0x0605_0403), std.mem.readInt(u32, group[140..144], .little));
    try std.testing.expectEqual(@as(u16, 0x0201), std.mem.readInt(u16, group[144..146], .little));
    try std.testing.expectEqualSlices(u8, &(.{0} ** 6), group[156..162]);
}

test "an RSN element's group cipher: TKIP told apart" {
    // Version 1, group TKIP, pairwise CCMP, PSK.
    const element = [_]u8{ 48, 20, 1, 0, 0x00, 0x0F, 0xAC, 2, 1, 0, 0x00, 0x0F, 0xAC, 4, 1, 0, 0x00, 0x0F, 0xAC, 2, 0, 0 };
    const suites = scan.rsnSuites(&element).?;
    try std.testing.expect(suites.group_tkip and suites.ccmp and !suites.tkip and suites.psk);
}
