// SPDX-License-Identifier: MIT
//! The bits of an AAC packet, read most significant first. Reading past
//! the end gives zeros and is noticed (`overrun`), so a packet cut short
//! is found once, after the syntax that read it.

pub const Bits = struct {
    bytes: []const u8,
    /// Bits read from the start.
    at: usize = 0,

    /// The next `count` bits (1 to 25) without reading them.
    pub fn peek(b: *const Bits, count: u5) u32 {
        const byte = b.at >> 3;
        var word: u32 = 0;
        inline for (0..4) |i| {
            word = (word << 8) | (if (byte + i < b.bytes.len) b.bytes[byte + i] else 0);
        }
        return (word << @intCast(b.at & 7)) >> @intCast(32 - @as(u6, count));
    }

    /// The next `count` bits (0 to 25), read.
    pub fn read(b: *Bits, count: u5) u32 {
        if (count == 0) return 0;
        const value = b.peek(count);
        b.at += count;
        return value;
    }

    pub fn bit(b: *Bits) bool {
        return b.read(1) != 0;
    }

    pub fn skip(b: *Bits, count: usize) void {
        b.at += count;
    }

    /// On to the next whole byte.
    pub fn alignByte(b: *Bits) void {
        b.at = (b.at + 7) & ~@as(usize, 7);
    }

    /// Whether more was read than the packet has.
    pub fn overrun(b: *const Bits) bool {
        return b.at > b.bytes.len * 8;
    }

    /// The bits left.
    pub fn left(b: *const Bits) usize {
        return b.bytes.len * 8 -| b.at;
    }
};

test "bits read most significant first, zeros past the end" {
    const std = @import("std");
    var b: Bits = .{ .bytes = &.{ 0b1011_0011, 0xF0 } };
    try std.testing.expectEqual(@as(u32, 0b101), b.read(3));
    try std.testing.expectEqual(@as(u32, 0b1_0011_1111), b.read(9));
    try std.testing.expect(!b.bit());
    try std.testing.expect(!b.overrun());
    b.alignByte();
    try std.testing.expectEqual(@as(usize, 16), b.at);
    try std.testing.expectEqual(@as(u32, 0), b.read(8));
    try std.testing.expect(b.overrun());
}
