// SPDX-License-Identifier: MPL-2.0
//! Brightness and two colour differences, three planes at full size, turned
//! into blue, green and red - three bytes a pixel, blue first - with
//! JFIF's full-range matrix:
//!
//!   R = Y + 1.402 (Cr - 128)
//!   G = Y - 0.344136 (Cb - 128) - 0.714136 (Cr - 128)
//!   B = Y + 1.772 (Cb - 128)
//!
//! in 16-bit fixed point, rounded, each result held to 0..255. For a codec
//! that writes planes and no red, green and blue of its own (the JH7110's).

/// The matrix's factors, times 65536, and a half for rounding.
const cr_r: i32 = 91881;
const cb_g: i32 = 22554;
const cr_g: i32 = 46802;
const cb_b: i32 = 116130;
const half: i32 = 1 << 15;

/// The three planes, `stride` bytes a row each.
pub const Planes = struct {
    y: [*]const u8,
    cb: [*]const u8,
    cr: [*]const u8,
    stride: usize,
};

inline fn clamp(v: i32) u8 {
    return @intCast(@max(0, @min(255, v)));
}

/// `width` x `height` pixels of `planes` written to `out`, `pitch` bytes
/// from one row to the next.
pub fn toBgr(planes: Planes, out: [*]u8, pitch: usize, width: usize, height: usize) void {
    var row: usize = 0;
    while (row < height) : (row += 1) {
        const y = planes.y + row * planes.stride;
        const cb = planes.cb + row * planes.stride;
        const cr = planes.cr + row * planes.stride;
        const to = out + row * pitch;
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const l: i32 = y[x];
            const b: i32 = @as(i32, cb[x]) - 128;
            const r: i32 = @as(i32, cr[x]) - 128;
            to[x * 3] = clamp(l + ((cb_b * b + half) >> 16));
            to[x * 3 + 1] = clamp(l + ((half - cb_g * b - cr_g * r) >> 16));
            to[x * 3 + 2] = clamp(l + ((cr_r * r + half) >> 16));
        }
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "grey stays grey, the primaries come out where JFIF puts them" {
    // Black, white, mid grey; then pure red, green and blue as a JFIF
    // encoder writes them (rounded).
    const y = [_]u8{ 0, 255, 128, 76, 150, 29 };
    const cb = [_]u8{ 128, 128, 128, 85, 44, 255 };
    const cr = [_]u8{ 128, 128, 128, 255, 21, 107 };
    var out: [y.len * 3]u8 = undefined;
    toBgr(.{ .y = &y, .cb = &cb, .cr = &cr, .stride = y.len }, &out, out.len, y.len, 1);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, out[0..3]);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255 }, out[3..6]);
    try testing.expectEqualSlices(u8, &.{ 128, 128, 128 }, out[6..9]);
    const near = struct {
        fn check(pixel: []const u8, want: [3]u8) !void {
            for (pixel, want) |got, w| try testing.expect(@abs(@as(i32, got) - w) <= 2);
        }
    };
    try near.check(out[9..12], .{ 0, 0, 254 });
    try near.check(out[12..15], .{ 0, 255, 0 });
    try near.check(out[15..18], .{ 255, 0, 0 });
}

test "rows from the stride, written a pitch apart; what lies past the width is left" {
    const y = [_]u8{ 10, 20, 99, 30, 40, 99 };
    const c = [_]u8{128} ** 6;
    var out = [_]u8{0xAA} ** 16;
    toBgr(.{ .y = &y, .cb = &c, .cr = &c, .stride = 3 }, &out, 8, 2, 2);
    try testing.expectEqualSlices(u8, &.{ 10, 10, 10, 20, 20, 20, 0xAA, 0xAA }, out[0..8]);
    try testing.expectEqualSlices(u8, &.{ 30, 30, 30, 40, 40, 40, 0xAA, 0xAA }, out[8..16]);
}
