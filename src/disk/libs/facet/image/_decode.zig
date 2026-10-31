// SPDX-License-Identifier: MIT
//! Texels of a format an image does not keep: a compressed one (BC1, BC2,
//! BC3) or a float one, unpacked as they come in by CmdCopyBufferToImage into
//! the 8 bits a channel the image is kept in, whichever device samples it.
//!
//! Neither keeps what it would on a GPU with such textures. A compressed image
//! takes the memory of an uncompressed one. What is above 1 in a float image
//! is cut to 1, and below 0 to 0: the rasterizer's tiles and the formats
//! facet.library draws into have 8 bits a channel, or fewer.

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;

/// Whether an image of `format` is kept as 8 bits a channel.
pub fn unpacks(format: facet.Format) bool {
    return blockBytes(format) != 0 or texelBytes(format) != 0;
}

/// The bytes of a block of 4 x 4 texels of a compressed format; 0 for another.
pub fn blockBytes(format: facet.Format) u32 {
    return switch (format) {
        .bc1_rgb_unorm_block, .bc1_rgba_unorm_block => 8,
        .bc2_unorm_block, .bc3_unorm_block => 16,
        else => 0,
    };
}

/// The bytes of a texel of a float format; 0 for another.
pub fn texelBytes(format: facet.Format) u32 {
    return switch (format) {
        .r16g16b16a16_sfloat => 8,
        .r32g32b32a32_sfloat => 16,
        .b10g11r11_ufloat_pack32, .e5b9g9r9_ufloat_pack32 => 4,
        else => 0,
    };
}

/// Red, green, blue and alpha of 8 bits.
pub const Rgba = [4]u8;

/// A 16-bit colour's channels, each to 8 bits.
fn expanded(color: u16) [3]u32 {
    const r: u32 = color >> 11 & 0x1F;
    const g: u32 = color >> 5 & 0x3F;
    const b: u32 = color & 0x1F;
    return .{ r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2 };
}

fn between(a: u32, b: u32, a_parts: u32, b_parts: u32) u8 {
    return @intCast((a * a_parts + b * b_parts + (a_parts + b_parts) / 2) / (a_parts + b_parts));
}

/// The four colours of a colour block. `with_clear`: where the first number
/// is not above the second, the third is halfway and the last clear black.
fn palette(block: []const u8, with_clear: bool) [4]Rgba {
    const first = std.mem.readInt(u16, block[0..2], .little);
    const second = std.mem.readInt(u16, block[2..4], .little);
    const a = expanded(first);
    const b = expanded(second);
    var made: [4]Rgba = undefined;
    made[0] = .{ @intCast(a[0]), @intCast(a[1]), @intCast(a[2]), 255 };
    made[1] = .{ @intCast(b[0]), @intCast(b[1]), @intCast(b[2]), 255 };
    if (with_clear and first <= second) {
        made[2] = .{ between(a[0], b[0], 1, 1), between(a[1], b[1], 1, 1), between(a[2], b[2], 1, 1), 255 };
        made[3] = .{ 0, 0, 0, 0 };
    } else {
        made[2] = .{ between(a[0], b[0], 2, 1), between(a[1], b[1], 2, 1), between(a[2], b[2], 2, 1), 255 };
        made[3] = .{ between(a[0], b[0], 1, 2), between(a[1], b[1], 1, 2), between(a[2], b[2], 1, 2), 255 };
    }
    return made;
}

/// The alphas of a BC3 block's first eight bytes, for texels 0 to 15.
fn alphas(block: []const u8) [16]u8 {
    const a: u32 = block[0];
    const b: u32 = block[1];
    var values: [8]u8 = undefined;
    values[0] = block[0];
    values[1] = block[1];
    if (a > b) {
        for (2..8) |k| {
            const parts: u32 = @intCast(k - 1);
            values[k] = between(a, b, 7 - parts, parts);
        }
    } else {
        for (2..6) |k| {
            const parts: u32 = @intCast(k - 1);
            values[k] = between(a, b, 5 - parts, parts);
        }
        values[6] = 0;
        values[7] = 255;
    }
    var bits: u64 = 0;
    for (block[2..8], 0..) |byte, k| bits |= @as(u64, byte) << @intCast(k * 8);
    var made: [16]u8 = undefined;
    for (&made, 0..) |*alpha, k| alpha.* = values[@intCast(bits >> @intCast(k * 3) & 7)];
    return made;
}

/// A block's 16 texels, in rows.
pub fn block16(format: facet.Format, block: []const u8) [16]Rgba {
    const colors_at: usize = if (blockBytes(format) == 16) 8 else 0;
    const colors = block[colors_at..];
    const table = palette(colors, format == .bc1_rgb_unorm_block or format == .bc1_rgba_unorm_block);
    const indices = std.mem.readInt(u32, colors[4..8], .little);
    var made: [16]Rgba = undefined;
    for (&made, 0..) |*each, k| each.* = table[indices >> @intCast(k * 2) & 3];
    switch (format) {
        // No alpha to speak of: what is clear is black.
        .bc1_rgb_unorm_block => for (&made) |*each| {
            each[3] = 255;
        },
        .bc2_unorm_block => {
            const bits = std.mem.readInt(u64, block[0..8], .little);
            for (&made, 0..) |*each, k| {
                const alpha: u8 = @intCast(bits >> @intCast(k * 4) & 15);
                each[3] = alpha << 4 | alpha;
            }
        },
        .bc3_unorm_block => {
            const values = alphas(block);
            for (&made, values) |*each, alpha| each[3] = alpha;
        },
        else => {},
    }
    return made;
}

/// A float to 8 bits; NaN to 0.
fn byteOf(value: f32) u8 {
    if (!(value > 0)) return 0;
    if (value >= 1) return 255;
    return @intFromFloat(value * 255 + 0.5);
}

/// A half-float's value, by hand: not every processor the disk is built for
/// has f16 to spare.
fn ofHalf(half: u16) f32 {
    const negative = half & 0x8000 != 0;
    const exponent: u32 = half >> 10 & 0x1F;
    const mantissa: u32 = half & 0x3FF;
    if (exponent == 31 and mantissa != 0) return std.math.nan(f32);
    const value = ofParts(exponent, mantissa, 10, 15);
    return if (negative) -value else value;
}

/// An unsigned float of `bits` of mantissa, its exponent biased by `bias`.
fn ofParts(exponent: u32, mantissa: u32, comptime bits: u5, comptime bias: i32) f32 {
    const whole: f32 = @floatFromInt(mantissa);
    const scale = @as(f32, @floatFromInt(@as(u32, 1) << bits));
    if (exponent == 0) return std.math.ldexp(whole / scale, 1 - bias);
    return std.math.ldexp(1 + whole / scale, @as(i32, @intCast(exponent)) - bias);
}

/// A texel of a float format.
pub fn texel(format: facet.Format, bytes: []const u8) Rgba {
    return switch (format) {
        .r16g16b16a16_sfloat => made: {
            var channels: Rgba = undefined;
            for (&channels, 0..) |*channel, k| channel.* = byteOf(ofHalf(std.mem.readInt(u16, bytes[k * 2 ..][0..2], .little)));
            break :made channels;
        },
        .r32g32b32a32_sfloat => made: {
            var channels: Rgba = undefined;
            for (&channels, 0..) |*channel, k| channel.* = byteOf(@bitCast(std.mem.readInt(u32, bytes[k * 4 ..][0..4], .little)));
            break :made channels;
        },
        .b10g11r11_ufloat_pack32 => made: {
            const word = std.mem.readInt(u32, bytes[0..4], .little);
            const r = ofParts(word >> 6 & 0x1F, word & 0x3F, 6, 15);
            const g = ofParts(word >> 17 & 0x1F, word >> 11 & 0x3F, 6, 15);
            const b = ofParts(word >> 27 & 0x1F, word >> 22 & 0x1F, 5, 15);
            break :made .{ byteOf(r), byteOf(g), byteOf(b), 255 };
        },
        .e5b9g9r9_ufloat_pack32 => made: {
            const word = std.mem.readInt(u32, bytes[0..4], .little);
            const scale = std.math.ldexp(@as(f32, 1), @as(i32, @intCast(word >> 27)) - 15 - 9);
            const r: f32 = @floatFromInt(word & 0x1FF);
            const g: f32 = @floatFromInt(word >> 9 & 0x1FF);
            const b: f32 = @floatFromInt(word >> 18 & 0x1FF);
            break :made .{ byteOf(r * scale), byteOf(g * scale), byteOf(b * scale), 255 };
        },
        else => .{ 0, 0, 0, 0 },
    };
}

const testing = std.testing;

test "BC1: four colours, or three and clear" {
    // Red, then blue; texels 0, 1, 2 and 3 in order.
    const four = [8]u8{ 0x00, 0xF8, 0x1F, 0x00, 0xE4, 0xE4, 0xE4, 0xE4 };
    var made = block16(.bc1_rgba_unorm_block, &four);
    try testing.expectEqual(Rgba{ 255, 0, 0, 255 }, made[0]);
    try testing.expectEqual(Rgba{ 0, 0, 255, 255 }, made[1]);
    try testing.expectEqual(Rgba{ 170, 0, 85, 255 }, made[2]);
    try testing.expectEqual(Rgba{ 85, 0, 170, 255 }, made[3]);
    // Blue, then red: three colours, and clear.
    const three = [8]u8{ 0x1F, 0x00, 0x00, 0xF8, 0xE4, 0xE4, 0xE4, 0xE4 };
    made = block16(.bc1_rgba_unorm_block, &three);
    try testing.expectEqual(Rgba{ 128, 0, 128, 255 }, made[2]);
    try testing.expectEqual(Rgba{ 0, 0, 0, 0 }, made[3]);
    made = block16(.bc1_rgb_unorm_block, &three);
    try testing.expectEqual(Rgba{ 0, 0, 0, 255 }, made[3]);
}

test "BC2 and BC3: the alpha apart" {
    var block = [16]u8{ 0x10, 0x32, 0, 0, 0, 0, 0xFF, 0xFF, 0x00, 0xF8, 0x1F, 0x00, 0, 0, 0, 0 };
    var made = block16(.bc2_unorm_block, &block);
    try testing.expectEqual(@as(u8, 0x00), made[0][3]);
    try testing.expectEqual(@as(u8, 0x11), made[1][3]);
    try testing.expectEqual(@as(u8, 0x33), made[3][3]);
    try testing.expectEqual(@as(u8, 0xFF), made[15][3]);
    // The first two alphas, then 3 bits each: index 1, then 2 for the next.
    block = .{ 200, 100, 0b010_001, 0, 0, 0, 0, 0, 0x00, 0xF8, 0x1F, 0x00, 0, 0, 0, 0 };
    made = block16(.bc3_unorm_block, &block);
    try testing.expectEqual(@as(u8, 100), made[0][3]);
    try testing.expectEqual(@as(u8, 186), made[1][3]);
    try testing.expectEqual(@as(u8, 200), made[2][3]);
    try testing.expectEqual(Rgba{ 255, 0, 0, 200 }, made[2]);
}

test "floats: cut to what 8 bits hold" {
    const half = [8]u8{ 0x00, 0x3C, 0x00, 0x38, 0x00, 0x40, 0x00, 0xBC };
    try testing.expectEqual(Rgba{ 255, 128, 255, 0 }, texel(.r16g16b16a16_sfloat, &half));
    var floats: [16]u8 = undefined;
    for ([4]f32{ 0.25, 1.5, -1, 1 }, 0..) |value, k| std.mem.writeInt(u32, floats[k * 4 ..][0..4], @bitCast(value), .little);
    try testing.expectEqual(Rgba{ 64, 255, 0, 255 }, texel(.r32g32b32a32_sfloat, &floats));
    // Exponent 15 of each is 1: r, g and b; mantissas nothing.
    var word: u32 = 15 << 6 | 14 << 17 | 13 << 27;
    try testing.expectEqual(Rgba{ 255, 128, 64, 255 }, texel(.b10g11r11_ufloat_pack32, std.mem.asBytes(&word)));
    // 256 / 512 at an exponent of 15 is a half; a quarter for the next.
    word = 256 | 128 << 9 | 511 << 18 | 15 << 27;
    const made = texel(.e5b9g9r9_ufloat_pack32, std.mem.asBytes(&word));
    try testing.expectEqual(Rgba{ 128, 64, 255, 255 }, made);
    try testing.expectEqual(@as(f32, 1), ofHalf(0x3C00));
    try testing.expectEqual(@as(f32, 0.5), ofHalf(0x3800));
    try testing.expect(std.math.isNan(ofHalf(0x7C01)));
}
