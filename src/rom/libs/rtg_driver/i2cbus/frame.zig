// SPDX-License-Identifier: MPL-2.0
//! What goes on the wire for one transfer to a display on a command bus.
//!
//! A part on such a bus wants, in front of everything else, a few control
//! bytes with one bit in them saying whether a command or pixels follow.
//! Then comes the command word, at whatever width the part reads commands,
//! and then the bytes themselves. How many control bytes there are, which
//! bit it is and which way round it means what are all the part's business
//! and none of the bus's, so they are configured and this is the one place
//! that lays them out.
//!
//! It is a plain function over a buffer so that it can be checked without
//! a bus, a part or a machine to run them on.

const std = @import("std");

/// How the part wants a transfer laid out.
pub const Shape = struct {
    /// How many control bytes go in front. 0: none.
    control_bytes: u32 = 1,
    /// Which bit of every control byte says pixels follow.
    dc_bit: u32 = 6,
    /// That bit clear means pixels, rather than set.
    dc_low_on_data: bool = false,
    /// Bits a command word: 8 or 16.
    cmd_bits: u32 = 8,
};

/// Lay a transfer into `out`: the control bytes, the command (below zero
/// for none) and the bytes after it. How many bytes were written, or null
/// if the buffer is too small or the command too wide for its width.
pub fn build(out: []u8, shape: Shape, is_data: bool, cmd: i32, payload: []const u8) ?usize {
    const cmd_bytes: usize = if (cmd < 0) 0 else switch (shape.cmd_bits) {
        8 => 1,
        16 => 2,
        else => return null,
    };
    if (cmd >= 0 and cmd_bytes == 1 and cmd > 0xFF) return null;
    if (cmd >= 0 and cmd_bytes == 2 and cmd > 0xFFFF) return null;

    const control: usize = shape.control_bytes;
    const total = control + cmd_bytes + payload.len;
    if (total > out.len) return null;

    // The control bytes: the same byte as often as the part wants it.
    const bit_set = if (shape.dc_low_on_data) !is_data else is_data;
    const control_byte: u8 = if (bit_set) @as(u8, 1) << @intCast(shape.dc_bit) else 0;
    var at: usize = 0;
    while (at < control) : (at += 1) out[at] = control_byte;

    // The command, most significant byte first.
    if (cmd_bytes == 2) {
        out[at] = @truncate(@as(u32, @intCast(cmd)) >> 8);
        at += 1;
    }
    if (cmd_bytes != 0) {
        out[at] = @truncate(@as(u32, @intCast(cmd)));
        at += 1;
    }

    @memcpy(out[at..][0..payload.len], payload);
    return total;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "a transfer: control bytes, then the command, then the bytes" {
    var out: [8]u8 = undefined;
    const shape = Shape{ .control_bytes = 1, .dc_bit = 6, .cmd_bits = 8 };

    // A command and two parameters: the control byte says "not pixels".
    const count = build(&out, shape, false, 0x2A, &.{ 0x11, 0x22 }).?;
    try testing.expectEqual(@as(usize, 4), count);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x2A, 0x11, 0x22 }, out[0..count]);

    // The same, with pixels: the bit is set.
    const pixels = build(&out, shape, true, 0x2C, &.{0xFF}).?;
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x2C, 0xFF }, out[0..pixels]);
}

test "a transfer: no control phase, a wide command, no command at all" {
    var out: [8]u8 = undefined;

    const bare = Shape{ .control_bytes = 0, .cmd_bits = 8 };
    const count = build(&out, bare, false, 0x30, &.{0x01}).?;
    try testing.expectEqualSlices(u8, &.{ 0x30, 0x01 }, out[0..count]);

    const wide = Shape{ .control_bytes = 0, .cmd_bits = 16 };
    const two = build(&out, wide, false, 0x1234, &.{}).?;
    try testing.expectEqualSlices(u8, &.{ 0x12, 0x34 }, out[0..two]);
    // A command that does not fit its width is refused rather than cut.
    try testing.expect(build(&out, Shape{ .control_bytes = 0, .cmd_bits = 8 }, false, 0x1234, &.{}) == null);
    // A width the bus does not have.
    try testing.expect(build(&out, Shape{ .cmd_bits = 12 }, false, 1, &.{}) == null);

    // Below zero: the bytes alone, behind the control phase.
    const only = build(&out, Shape{ .control_bytes = 1, .dc_bit = 6 }, true, -1, &.{ 1, 2, 3 }).?;
    try testing.expectEqualSlices(u8, &.{ 0x40, 1, 2, 3 }, out[0..only]);
}

test "a transfer: two control bytes, the other way round, and one too big" {
    var out: [6]u8 = undefined;

    const two_bytes = Shape{ .control_bytes = 2, .dc_bit = 7, .dc_low_on_data = true };
    // Pixels with the bit meaning the other thing: the byte is clear.
    const data = build(&out, two_bytes, true, -1, &.{0xAB}).?;
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0xAB }, out[0..data]);
    // And a command sets it.
    const command = build(&out, two_bytes, false, 0x01, &.{}).?;
    try testing.expectEqualSlices(u8, &.{ 0x80, 0x80, 0x01 }, out[0..command]);

    // More than the buffer holds is refused, not truncated.
    try testing.expect(build(&out, two_bytes, false, 0x01, &.{ 1, 2, 3, 4, 5 }) == null);
}
