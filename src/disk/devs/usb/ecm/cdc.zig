// SPDX-License-Identifier: MIT
//! What a CDC Ethernet function says and is told, apart from the bus: its
//! Ethernet address as its descriptor's string gives it, the packet
//! filter asked of it, and its connection notification.

const sdk = @import("sdk");
const d = sdk.usb.descriptors;

/// SET_ETHERNET_PACKET_FILTER's bits: every frame, every group's frame,
/// the frames to the function's own address, broadcasts.
pub const PACKET_PROMISCUOUS: u16 = 1 << 0;
pub const PACKET_ALL_MULTICAST: u16 = 1 << 1;
pub const PACKET_DIRECTED: u16 = 1 << 2;
pub const PACKET_BROADCAST: u16 = 1 << 3;

/// A notification's bmRequestType: class, interface, device to host.
const notification_type: u8 = 0xA1;

/// The Ethernet address in iMACAddress's string: twelve hex digits, the
/// first byte's first; null for anything else.
pub fn addressOf(text: []const u8) ?[6]u8 {
    if (text.len != 12) return null;
    var address: [6]u8 = undefined;
    for (&address, 0..) |*byte, index| {
        const high = digit(text[2 * index]) orelse return null;
        const low = digit(text[2 * index + 1]) orelse return null;
        byte.* = high << 4 | low;
    }
    return address;
}

fn digit(character: u8) ?u8 {
    return switch (character) {
        '0'...'9' => character - '0',
        'A'...'F' => character - 'A' + 10,
        'a'...'f' => character - 'a' + 10,
        else => null,
    };
}

/// The filter a unit asks for: its own frames and broadcasts, every
/// group's once it has joined one - the unit sorts out which it wants -
/// and everything for a promiscuous opener.
pub fn packetFilter(joined: bool, promiscuous: bool) u16 {
    var bits = PACKET_DIRECTED | PACKET_BROADCAST;
    if (joined) bits |= PACKET_ALL_MULTICAST;
    if (promiscuous) bits |= PACKET_PROMISCUOUS;
    return bits;
}

/// The carrier a NETWORK_CONNECTION notification says; null for any
/// other notification, or a piece of one.
pub fn connection(report: []const u8) ?bool {
    if (report.len < 8 or report[0] != notification_type) return null;
    if (report[1] != d.CDC_NOTIFY_NETWORK_CONNECTION) return null;
    return report[2] != 0;
}

const std = @import("std");

test "the address string" {
    try std.testing.expectEqual([6]u8{ 0x40, 0x01, 0x02, 0x03, 0x04, 0x05 }, addressOf("400102030405").?);
    try std.testing.expectEqual([6]u8{ 0xDE, 0xAD, 0xbe, 0xef, 0x00, 0xFF }, addressOf("DEADbeef00ff").?);
    try std.testing.expect(addressOf("40010203040") == null);
    try std.testing.expect(addressOf("4001020304050") == null);
    try std.testing.expect(addressOf("40010203040g") == null);
}

test "the packet filter" {
    try std.testing.expectEqual(PACKET_DIRECTED | PACKET_BROADCAST, packetFilter(false, false));
    try std.testing.expectEqual(PACKET_DIRECTED | PACKET_BROADCAST | PACKET_ALL_MULTICAST, packetFilter(true, false));
    try std.testing.expect(packetFilter(false, true) & PACKET_PROMISCUOUS != 0);
}

test "the connection notification" {
    try std.testing.expectEqual(true, connection(&.{ 0xA1, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00 }).?);
    try std.testing.expectEqual(false, connection(&.{ 0xA1, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }).?);
    // A speed change, and its data arriving as a packet of its own.
    try std.testing.expect(connection(&.{ 0xA1, 0x2A, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00 }) == null);
    try std.testing.expect(connection(&.{ 0x00, 0x1B, 0xB7, 0x00, 0x00, 0x1B, 0xB7, 0x00 }) == null);
    try std.testing.expect(connection(&.{ 0xA1, 0x00 }) == null);
}
