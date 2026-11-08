// SPDX-License-Identifier: MIT
//! Host tests of what realnet.device writes into a descriptor
//! (`devs/networks/realnet/ring.zig`) and of the hash its receive filter
//! puts a group in (`.../mac.zig`).
//!
//! **The hash is the thing worth proving here.** Which of the 64 bits a
//! group address falls in is the top six bits of the frame check
//! sequence over its six bytes, worked out most significant bit first
//! with the bits of each byte taken least significant first - a sequence
//! that is not the one a checksum over a file is. A bit worked out wrong
//! is a group whose frames never arrive, which looks like a dead network
//! rather than like a filter. The values below are the standard
//! sequence's, which the controller's own filter works out the same way:
//! for the addresses here they are the complement of what a widely used
//! implementation gives, with its bits in the other order.
//!
//! The controller itself is proved on a machine that has one.

const std = @import("std");
const mac = @import("../realnet/mac.zig");
const ring = @import("../realnet/ring.zig");

const testing = std.testing;

test "a group falls in the hash bit its frame check sequence names" {
    const cases = [_]struct { address: [6]u8, bit: u32 }{
        .{ .address = .{ 0x01, 0x00, 0x5e, 0x00, 0x00, 0x01 }, .bit = 31 },
        .{ .address = .{ 0x33, 0x33, 0x00, 0x00, 0x00, 0x01 }, .bit = 62 },
        .{ .address = .{ 0x01, 0x80, 0xc2, 0x00, 0x00, 0x0e }, .bit = 33 },
        .{ .address = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, .bit = 63 },
        .{ .address = .{ 0x01, 0x00, 0x5e, 0x7f, 0xff, 0xfa }, .bit = 43 },
        .{ .address = .{ 0x01, 0x00, 0x5e, 0x01, 0x02, 0x03 }, .bit = 57 },
    };
    for (cases) |case| {
        try testing.expectEqual(case.bit, mac.groupHash(&case.address));
    }
}

test "every hash bit is one of the 64 there are" {
    var address: [6]u8 = .{ 0x01, 0x00, 0x5e, 0x00, 0x00, 0x00 };
    var seen: u64 = 0;
    var which: u32 = 0;
    while (which < 256) : (which += 1) {
        address[5] = @truncate(which);
        const bit = mac.groupHash(&address);
        try testing.expect(bit < 64);
        seen |= @as(u64, 1) << @truncate(bit);
    }
    // 256 addresses over 64 bits reach all of them.
    try testing.expectEqual(~@as(u64, 0), seen);
}

test "a descriptor is what the controller walks" {
    try testing.expectEqual(32, @sizeOf(ring.Receive));
    try testing.expectEqual(32, @sizeOf(ring.Transmit));
    // Where each side's words are: the controller reads the address at
    // 16 bytes into a receive descriptor and writes its answer at 24.
    try testing.expectEqual(16, @offsetOf(ring.Receive, "address"));
    try testing.expectEqual(24, @offsetOf(ring.Receive, "extra"));
    try testing.expectEqual(28, @offsetOf(ring.Receive, "command"));
    try testing.expectEqual(0, @offsetOf(ring.Transmit, "command"));
    try testing.expectEqual(8, @offsetOf(ring.Transmit, "address"));
}

test "a descriptor handed over says whose it is, and the last says where the ring ends" {
    var descriptor: ring.Receive = .{};
    ring.give(&descriptor, 0x1234_5678_9abc, 2048, false);
    try testing.expectEqual(@as(u64, 0x1234_5678_9abc), descriptor.address);
    try testing.expectEqual(ring.own | 2048, descriptor.command);
    try testing.expect(!ring.done(descriptor.command));

    ring.give(&descriptor, 0x2000, 2048, true);
    try testing.expectEqual(ring.own | ring.end_of_ring | 2048, descriptor.command);

    var out: ring.Transmit = .{};
    ring.send(&out, 0x3000, 60, false);
    try testing.expectEqual(ring.own | ring.sent_first | ring.sent_last | 60, out.command);
    ring.send(&out, 0x3000, 60, true);
    try testing.expect(out.command & ring.end_of_ring != 0);

    // Given back is the ownership bit cleared, and nothing else.
    out.command &= ~ring.own;
    try testing.expect(ring.done(out.command));
}

test "a frame's length is the low bits of the word the controller wrote" {
    var descriptor: ring.Receive = .{};
    descriptor.command = 0x8000_0000 | 0x0300_0000 | 1518;
    try testing.expectEqual(@as(u32, 1518), ring.frameBytes(&descriptor));
    // The length field is fourteen bits; the flags above it are no part
    // of it.
    descriptor.command = 0xffff_c000 | 64;
    try testing.expectEqual(@as(u32, 64), ring.frameBytes(&descriptor));
}

test "a packet is answered as checked only where there was something to check" {
    const ipv4: u32 = 0x4000_0000;
    const ipv6: u32 = 0x8000_0000;
    const tcp: u32 = 0x1000_0000;
    const udp: u32 = 0x2000_0000;
    const tcp_bad: u32 = 0x0100_0000;
    const ip_bad: u32 = 0x0400_0000;
    var descriptor: ring.Receive = .{};

    descriptor.extra = ipv4 | tcp;
    try testing.expect(ring.receivedChecked(&descriptor));
    descriptor.extra = ipv6 | udp;
    try testing.expect(ring.receivedChecked(&descriptor));

    // A frame that is no packet of a kind it knows, and a packet whose
    // transport part is neither: nothing was checked.
    descriptor.extra = 0;
    try testing.expect(!ring.receivedChecked(&descriptor));
    descriptor.extra = ipv4;
    try testing.expect(!ring.receivedChecked(&descriptor));

    // And a packet it checked and found wrong.
    descriptor.extra = ipv4 | tcp | tcp_bad;
    try testing.expect(!ring.receivedChecked(&descriptor));
    descriptor.extra = ipv4 | udp | ip_bad;
    try testing.expect(!ring.receivedChecked(&descriptor));
}
