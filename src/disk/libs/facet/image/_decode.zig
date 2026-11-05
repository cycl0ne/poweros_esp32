// SPDX-License-Identifier: MIT
//! Texels of a format an image does not keep: a compressed one (BC1, BC2,
//! BC3) or a float one, unpacked as they come in by CmdCopyBufferToImage into
//! the 8 bits a channel the image is kept in.
//!
//! A compressed image is unpacked here only on a device that samples texels
//! rather than blocks (`PhysicalDeviceFeatures.kept_compressed`, false on the
//! V3D): it then takes the memory of an uncompressed one, and holds what
//! sampling the blocks would have read, the one decoder being the SDK's
//! (`texture.blockOf`). What is above 1 in a float image is cut to 1, and
//! below 0 to 0: the rasterizer's tiles and the formats facet.library draws
//! into have 8 bits a channel, or fewer.

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;
const texture = facet.texture;

/// Whether an image of `format` is kept as 8 bits a channel.
pub fn unpacks(format: facet.Format) bool {
    return blockBytes(format) != 0 or texelBytes(format) != 0;
}

/// The bytes of a block of 4 x 4 texels of a compressed format; 0 for another.
pub fn blockBytes(format: facet.Format) u32 {
    return switch (format) {
        .bc1_rgb_unorm_block, .bc1_rgba_unorm_block => 8,
        .bc2_unorm_block, .bc3_unorm_block => 16,
        // BC4 and BC5, one channel and two (since 1.72).
        .bc4_unorm_block => 8,
        .bc5_unorm_block => 16,
        // ETC2 and EAC (since 1.46): one 64-bit word for colour, and a
        // second for an alpha or a second channel.
        .etc2_r8g8b8_unorm_block, .etc2_r8g8b8a1_unorm_block, .eac_r11_unorm_block => 8,
        .etc2_r8g8b8a8_unorm_block, .eac_r11g11_unorm_block => 16,
        else => 0,
    };
}

/// Whether a block of `format` is an ETC2 or EAC one, which is decoded
/// here and never kept: no device of this library samples such a block.
pub fn etc(format: facet.Format) bool {
    return switch (format) {
        .etc2_r8g8b8_unorm_block, .etc2_r8g8b8a1_unorm_block, .etc2_r8g8b8a8_unorm_block, .eac_r11_unorm_block, .eac_r11g11_unorm_block => true,
        else => false,
    };
}

/// The bytes of a texel of a float format; 0 for another.
pub fn texelBytes(format: facet.Format) u32 {
    return switch (format) {
        .r16g16b16a16_sfloat => 8,
        .r32g32b32a32_sfloat => 16,
        // One float a texel, since 1.57.
        .b10g11r11_ufloat_pack32, .e5b9g9r9_ufloat_pack32, .r32_sfloat => 4,
        else => 0,
    };
}

/// Red, green, blue and alpha of 8 bits.
pub const Rgba = [4]u8;

// --- ETC2 and EAC -----------------------------------------------------------
//
// The Khronos Data Format Specification's ETC2 section has the bit layouts
// and the tables these follow. A block's eight bytes are one 64-bit word,
// the first byte the most significant; the sixteen texels are lettered a to
// p down the columns, so texel k is at (k / 4, k % 4).

/// A block's bytes as the one word the layouts are given in.
fn wordOf(block: []const u8) u64 {
    var made: u64 = 0;
    for (block[0..8]) |byte| made = made << 8 | byte;
    return made;
}

/// The intensity modifiers of the `individual' and `differential' modes,
/// by table codeword and by pixel index: the index picks +a, +b, -a, -b in
/// that order, which is what the specification's two tables together say.
const etc_modifiers = [8][4]i32{
    .{ 2, 8, -2, -8 },
    .{ 5, 17, -5, -17 },
    .{ 9, 29, -9, -29 },
    .{ 13, 42, -13, -42 },
    .{ 18, 60, -18, -60 },
    .{ 24, 80, -24, -80 },
    .{ 33, 106, -33, -106 },
    .{ 47, 183, -47, -183 },
};

/// The same where the punchthrough format's `opaque' bit is unset: the two
/// middle colours are the base colour itself, one of them clear.
const etc_punched = [8][4]i32{
    .{ 0, 8, 0, -8 },
    .{ 0, 17, 0, -17 },
    .{ 0, 29, 0, -29 },
    .{ 0, 42, 0, -42 },
    .{ 0, 60, 0, -60 },
    .{ 0, 80, 0, -80 },
    .{ 0, 106, 0, -106 },
    .{ 0, 183, 0, -183 },
};

/// The distances the `T' and `H' modes move the second base colour by.
const etc_distances = [8]i32{ 3, 6, 11, 16, 23, 32, 41, 64 };

/// The modifiers EAC takes, by table index and by the three-bit pixel
/// index: an alpha's, and a channel of 11 bits.
const eac_modifiers = [16][8]i32{
    .{ -3, -6, -9, -15, 2, 5, 8, 14 },
    .{ -3, -7, -10, -13, 2, 6, 9, 12 },
    .{ -2, -5, -8, -13, 1, 4, 7, 12 },
    .{ -2, -4, -6, -13, 1, 3, 5, 12 },
    .{ -3, -6, -8, -12, 2, 5, 7, 11 },
    .{ -3, -7, -9, -11, 2, 6, 8, 10 },
    .{ -4, -7, -8, -11, 3, 6, 7, 10 },
    .{ -3, -5, -8, -11, 2, 4, 7, 10 },
    .{ -2, -6, -8, -10, 1, 5, 7, 9 },
    .{ -2, -5, -8, -10, 1, 4, 7, 9 },
    .{ -2, -4, -8, -10, 1, 3, 7, 9 },
    .{ -2, -5, -7, -10, 1, 4, 6, 9 },
    .{ -3, -4, -7, -10, 2, 3, 6, 9 },
    .{ -1, -2, -3, -10, 0, 1, 2, 9 },
    .{ -4, -6, -8, -9, 3, 5, 7, 8 },
    .{ -3, -5, -7, -9, 2, 4, 6, 8 },
};

/// Bits repeated into the low ones, which is the value times 255 over the
/// largest the bits hold, to the nearest.
fn extend4(value: u32) u32 {
    return value << 4 | value;
}
fn extend5(value: u32) u32 {
    return value << 3 | value >> 2;
}
fn extend6(value: u32) u32 {
    return value << 2 | value >> 4;
}
fn extend7(value: u32) u32 {
    return value << 1 | value >> 6;
}

/// A three-bit two's-complement number, -4 to 3.
fn signed3(bits: u64) i32 {
    const value: i32 = @intCast(bits & 7);
    return if (value > 3) value - 8 else value;
}

fn clamp255(value: i32) u8 {
    return @intCast(std.math.clamp(value, 0, 255));
}

/// A base colour of 8 bits a channel with `by` added to each, clamped.
fn moved(base: [3]i32, by: i32) Rgba {
    return .{ clamp255(base[0] + by), clamp255(base[1] + by), clamp255(base[2] + by), 255 };
}

/// The sixteen texels of an ETC2 colour block, in rows. `punch` is the
/// punchthrough format, whose bit 33 is an `opaque' bit rather than the
/// `differential' one: where it is unset, the texel whose index is 2 is
/// clear black and the two middle modifiers are 0.
fn etcColors(word: u64, punch: bool) [16]Rgba {
    const red: i32 = @intCast(word >> 59 & 0x1F);
    const green: i32 = @intCast(word >> 51 & 0x1F);
    const blue: i32 = @intCast(word >> 43 & 0x1F);
    const sums = [3]i32{ red + signed3(word >> 56), green + signed3(word >> 48), blue + signed3(word >> 40) };
    const differs = punch or word >> 33 & 1 != 0;
    // Which mode: a sum outside 0 to 31 says T, H or planar, in that
    // order; the `differential' bit unset says `individual'.
    if (differs and (sums[0] < 0 or sums[0] > 31)) return etcSharp(word, true, punch);
    if (differs and (sums[1] < 0 or sums[1] > 31)) return etcSharp(word, false, punch);
    if (differs and (sums[2] < 0 or sums[2] > 31)) return etcPlanar(word);
    // Two subblocks, each a base colour and a table of modifiers.
    var bases: [2][3]i32 = undefined;
    if (differs) {
        bases[0] = .{ @intCast(extend5(@intCast(red))), @intCast(extend5(@intCast(green))), @intCast(extend5(@intCast(blue))) };
        bases[1] = .{ @intCast(extend5(@intCast(sums[0]))), @intCast(extend5(@intCast(sums[1]))), @intCast(extend5(@intCast(sums[2]))) };
    } else {
        bases[0] = .{ @intCast(extend4(@intCast(word >> 60 & 0xF))), @intCast(extend4(@intCast(word >> 52 & 0xF))), @intCast(extend4(@intCast(word >> 44 & 0xF))) };
        bases[1] = .{ @intCast(extend4(@intCast(word >> 56 & 0xF))), @intCast(extend4(@intCast(word >> 48 & 0xF))), @intCast(extend4(@intCast(word >> 40 & 0xF))) };
    }
    const opaque_block = !punch or word >> 33 & 1 != 0;
    const tables = [2]u32{ @intCast(word >> 37 & 7), @intCast(word >> 34 & 7) };
    const flipped = word >> 32 & 1 != 0;
    var made: [16]Rgba = undefined;
    for (&made, 0..) |*texel_out, k| {
        const x: u32 = @intCast(k / 4);
        const y: u32 = @intCast(k % 4);
        const second = if (flipped) y >= 2 else x >= 2;
        const index = etcIndex(word, k);
        const table = tables[if (second) 1 else 0];
        const by = if (opaque_block) etc_modifiers[table][index] else etc_punched[table][index];
        texel_out.* = if (!opaque_block and index == 2) .{ 0, 0, 0, 0 } else moved(bases[if (second) 1 else 0], by);
    }
    return made;
}

/// A texel's two-bit index: its high bit in the upper half of the low 32
/// bits and its low bit in the lower half.
fn etcIndex(word: u64, k: usize) u32 {
    const high: u32 = @intCast(word >> @intCast(16 + k) & 1);
    const low: u32 = @intCast(word >> @intCast(k) & 1);
    return high << 1 | low;
}

/// The `T' and `H' modes, which hold two base colours of 4 bits a channel
/// and a distance: four paint colours, the index picking one of them.
fn etcSharp(word: u64, t_mode: bool, punch: bool) [16]Rgba {
    var first: [3]i32 = undefined;
    var second: [3]i32 = undefined;
    var distance_index: u32 = undefined;
    if (t_mode) {
        const r: u32 = @intCast((word >> 59 & 3) << 2 | (word >> 56 & 3));
        first = .{ @intCast(extend4(r)), @intCast(extend4(@intCast(word >> 52 & 0xF))), @intCast(extend4(@intCast(word >> 48 & 0xF))) };
        second = .{ @intCast(extend4(@intCast(word >> 44 & 0xF))), @intCast(extend4(@intCast(word >> 40 & 0xF))), @intCast(extend4(@intCast(word >> 36 & 0xF))) };
        distance_index = @intCast((word >> 34 & 3) << 1 | (word >> 32 & 1));
    } else {
        const g: u32 = @intCast((word >> 56 & 7) << 1 | (word >> 52 & 1));
        const b: u32 = @intCast((word >> 51 & 1) << 3 | (word >> 47 & 7));
        first = .{ @intCast(extend4(@intCast(word >> 59 & 0xF))), @intCast(extend4(g)), @intCast(extend4(b)) };
        second = .{ @intCast(extend4(@intCast(word >> 43 & 0xF))), @intCast(extend4(@intCast(word >> 39 & 0xF))), @intCast(extend4(@intCast(word >> 35 & 0xF))) };
        // Its lowest bit is which base colour is the larger.
        const value_first = first[0] << 16 | first[1] << 8 | first[2];
        const value_second = second[0] << 16 | second[1] << 8 | second[2];
        distance_index = @intCast((word >> 34 & 1) << 2 | (word >> 32 & 1) << 1 | @as(u64, @intFromBool(value_first >= value_second)));
    }
    const d = etc_distances[distance_index];
    const paints = if (t_mode) [4]Rgba{
        moved(first, 0),
        moved(second, d),
        moved(second, 0),
        moved(second, -d),
    } else [4]Rgba{
        moved(first, d),
        moved(first, -d),
        moved(second, d),
        moved(second, -d),
    };
    const clear = punch and word >> 33 & 1 == 0;
    var made: [16]Rgba = undefined;
    for (&made, 0..) |*texel_out, k| {
        const index = etcIndex(word, k);
        texel_out.* = if (clear and index == 2) .{ 0, 0, 0, 0 } else paints[index];
    }
    return made;
}

/// The `planar' mode: three base colours of 676, and every texel on the
/// plane through them.
fn etcPlanar(word: u64) [16]Rgba {
    const origin = [3]i32{
        @intCast(extend6(@intCast(word >> 57 & 0x3F))),
        @intCast(extend7(@intCast((word >> 56 & 1) << 6 | (word >> 49 & 0x3F)))),
        @intCast(extend6(@intCast((word >> 48 & 1) << 5 | (word >> 43 & 3) << 3 | (word >> 39 & 7)))),
    };
    const across = [3]i32{
        @intCast(extend6(@intCast((word >> 34 & 0x1F) << 1 | (word >> 32 & 1)))),
        @intCast(extend7(@intCast(word >> 25 & 0x7F))),
        @intCast(extend6(@intCast(word >> 19 & 0x3F))),
    };
    const down = [3]i32{
        @intCast(extend6(@intCast(word >> 13 & 0x3F))),
        @intCast(extend7(@intCast(word >> 6 & 0x7F))),
        @intCast(extend6(@intCast(word & 0x3F))),
    };
    var made: [16]Rgba = undefined;
    for (&made, 0..) |*texel_out, k| {
        const x: i32 = @intCast(k / 4);
        const y: i32 = @intCast(k % 4);
        inline for (0..3) |channel| {
            texel_out[channel] = clamp255((x * (across[channel] - origin[channel]) + y * (down[channel] - origin[channel]) + 4 * origin[channel] + 2) >> 2);
        }
        texel_out[3] = 255;
    }
    return made;
}

/// The sixteen values of an EAC block: a base, a multiplier and a table,
/// and a three-bit index for each texel - texel a's in bits 47 to 45, down
/// to texel p's in bits 2 to 0. The value is 8 bits for an alpha and 11 for
/// a channel of R11, which this gives as its top 8.
fn eacValues(word: u64, eleven: bool) [16]u8 {
    const base: i32 = @intCast(word >> 56 & 0xFF);
    const multiplier: i32 = @intCast(word >> 52 & 0xF);
    const table = eac_modifiers[@intCast(word >> 48 & 0xF)];
    var made: [16]u8 = undefined;
    for (&made, 0..) |*value, k| {
        const index: usize = @intCast(word >> @intCast(45 - 3 * k) & 7);
        const modifier = table[index];
        if (eleven) {
            // 11 bits: the base times 8 and a half step on, the modifier
            // times the multiplier times 8 - or times one where the
            // multiplier is 0, which stands for an eighth.
            const moved_by = if (multiplier == 0) modifier else modifier * multiplier * 8;
            const whole = std.math.clamp(base * 8 + 4 + moved_by, 0, 2047);
            value.* = @intCast(whole >> 3);
        } else {
            value.* = clamp255(base + modifier * multiplier);
        }
    }
    return made;
}

/// Which texture format keeps a compressed one's blocks, for the decoder
/// the sampler uses as well (`texture.blockOf`).
fn keptBlocks(format: facet.Format) ?texture.Format {
    return switch (format) {
        .bc1_rgb_unorm_block => .bc1_rgb,
        .bc1_rgba_unorm_block => .bc1,
        .bc2_unorm_block => .bc2,
        .bc3_unorm_block => .bc3,
        .bc4_unorm_block => .bc4,
        .bc5_unorm_block => .bc5,
        else => null,
    };
}

/// A block's 16 texels, in rows: the SDK's decoder, which is the one a
/// sample of a kept block reads through, so an image unpacked as it is
/// copied in holds what sampling the blocks would have read.
pub fn block16(format: facet.Format, block: []const u8) [16]Rgba {
    var made: [16]Rgba = .{.{ 0, 0, 0, 0 }} ** 16;
    switch (format) {
        .etc2_r8g8b8_unorm_block => return etcColors(wordOf(block), false),
        .etc2_r8g8b8a1_unorm_block => return etcColors(wordOf(block), true),
        .etc2_r8g8b8a8_unorm_block => {
            // The alpha's word first, the colour's second.
            made = etcColors(wordOf(block[8..16]), false);
            const alphas_in = eacValues(wordOf(block[0..8]), false);
            for (&made, alphas_in) |*texel_out, alpha| texel_out[3] = alpha;
            return made;
        },
        .eac_r11_unorm_block => {
            const reds = eacValues(wordOf(block), true);
            for (&made, reds) |*texel_out, value| texel_out.* = .{ value, 0, 0, 255 };
            return made;
        },
        .eac_r11g11_unorm_block => {
            const reds = eacValues(wordOf(block[0..8]), true);
            const greens = eacValues(wordOf(block[8..16]), true);
            for (&made, reds, greens) |*texel_out, red, green| texel_out.* = .{ red, green, 0, 255 };
            return made;
        },
        else => {},
    }
    const kept = keptBlocks(format) orelse return made;
    switch (kept) {
        inline .bc1, .bc1_rgb, .bc2, .bc3, .bc4, .bc5 => |one| {
            const texels = texture.blockOf(one, block.ptr);
            for (&made, texels) |*each, color| each.* = .{
                @intCast(color >> 16 & 0xFF),
                @intCast(color >> 8 & 0xFF),
                @intCast(color & 0xFF),
                @intCast(color >> 24),
            };
        },
        else => {},
    }
    return made;
}

/// Which texture format keeps a float one's texels, for the decoder the
/// sampler uses as well (`texture.floatTexel`).
fn keptFloats(format: facet.Format) ?texture.Format {
    return switch (format) {
        .r16g16b16a16_sfloat => .rgba16f,
        .r32g32b32a32_sfloat => .rgba32f,
        .b10g11r11_ufloat_pack32 => .rg11b10f,
        .e5b9g9r9_ufloat_pack32 => .rgb9e5,
        // One float a texel, since 1.57.
        .r32_sfloat => .r32f,
        else => null,
    };
}

/// A texel of a float format, 8 bits a channel: the SDK's decoder, which
/// is the one a sample of a kept texel reads through, so an image unpacked
/// as it is copied in holds what sampling the floats would have read.
pub fn texel(format: facet.Format, bytes: []const u8) Rgba {
    const kept = keptFloats(format) orelse return .{ 0, 0, 0, 0 };
    var made: Rgba = .{ 0, 0, 0, 0 };
    switch (kept) {
        inline .rgba16f, .rgba32f, .rg11b10f, .rgb9e5, .r32f => |one| {
            const color = texture.floatTexel(one, bytes.ptr);
            made = .{
                @intCast(color >> 16 & 0xFF),
                @intCast(color >> 8 & 0xFF),
                @intCast(color & 0xFF),
                @intCast(color >> 24),
            };
        },
        else => {},
    }
    return made;
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

test "BC4 and BC5: one channel and two, the block BC3 keeps its alpha in" {
    // The six bytes of three-bit indices a block ends with, texel 0 first.
    const indexed = struct {
        fn indexed(each: []const u3) [6]u8 {
            var word: u64 = 0;
            for (each, 0..) |one, k| word |= @as(u64, one) << @intCast(k * 3);
            var made: [6]u8 = undefined;
            for (&made, 0..) |*byte, k| byte.* = @truncate(word >> @intCast(k * 8));
            return made;
        }
    }.indexed;
    const blockOf = struct {
        fn blockOf(ends: [2]u8, each: []const u3) [8]u8 {
            var made: [8]u8 = undefined;
            made[0] = ends[0];
            made[1] = ends[1];
            @memcpy(made[2..8], &indexed(each));
            return made;
        }
    }.blockOf;

    // Two endpoints, 200 and 100, then an index a texel: 0 is the first
    // endpoint, 1 the second, and 2 one seventh of the way back.
    var one = blockOf(.{ 200, 100 }, &.{ 0, 1, 2 });
    var made = block16(.bc4_unorm_block, &one);
    try testing.expectEqual(Rgba{ 200, 0, 0, 255 }, made[0]);
    try testing.expectEqual(Rgba{ 100, 0, 0, 255 }, made[1]);
    try testing.expectEqual(Rgba{ 186, 0, 0, 255 }, made[2]);
    // The first endpoint below the second: four values between, and 0 and
    // 255 at indices 6 and 7.
    one = blockOf(.{ 100, 200 }, &.{ 0, 1, 6, 7 });
    made = block16(.bc4_unorm_block, &one);
    try testing.expectEqual(Rgba{ 100, 0, 0, 255 }, made[0]);
    try testing.expectEqual(Rgba{ 200, 0, 0, 255 }, made[1]);
    try testing.expectEqual(Rgba{ 0, 0, 0, 255 }, made[2]);
    try testing.expectEqual(Rgba{ 255, 0, 0, 255 }, made[3]);

    // BC5 is two of those blocks, red's first and green's second.
    var two: [16]u8 = @splat(0);
    @memcpy(two[0..8], &blockOf(.{ 200, 100 }, &.{ 0, 1, 2 }));
    @memcpy(two[8..16], &blockOf(.{ 10, 250 }, &.{ 0, 1, 0 }));
    made = block16(.bc5_unorm_block, &two);
    try testing.expectEqual(Rgba{ 200, 10, 0, 255 }, made[0]);
    try testing.expectEqual(Rgba{ 100, 250, 0, 255 }, made[1]);
    try testing.expectEqual(Rgba{ 186, 10, 0, 255 }, made[2]);
    // The blue is 0 and the alpha whole, as Vulkan reads two channels.
    for (made) |each| {
        try testing.expectEqual(@as(u8, 0), each[2]);
        try testing.expectEqual(@as(u8, 255), each[3]);
    }
    // And a block of each is 8 bytes and 16.
    try testing.expectEqual(@as(u32, 8), blockBytes(.bc4_unorm_block));
    try testing.expectEqual(@as(u32, 16), blockBytes(.bc5_unorm_block));
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
    try testing.expectEqual(@as(f32, 1), texture.ofHalf(0x3C00));
    try testing.expectEqual(@as(f32, 0.5), texture.ofHalf(0x3800));
    try testing.expect(std.math.isNan(texture.ofHalf(0x7C01)));
}

/// A 64-bit word as the eight bytes of a block, the first the most
/// significant: how the specification's layouts are written.
fn bytesOfWord(word: u64) [8]u8 {
    var made: [8]u8 = undefined;
    for (&made, 0..) |*byte, k| byte.* = @truncate(word >> @intCast(56 - 8 * k));
    return made;
}

test "ETC2: the individual and differential modes, two subblocks each" {
    // Individual: the differential bit unset, subblock 1 red and subblock
    // 2 blue of 4 bits a channel, every texel index 0 - which is the
    // smaller positive modifier, +2 of table 0. Side by side, so the left
    // two columns are the first.
    var word: u64 = @as(u64, 0xF) << 60 | @as(u64, 0) << 56 | @as(u64, 0) << 52 | @as(u64, 0) << 48 | @as(u64, 0) << 44 | @as(u64, 0xF) << 40;
    var made = block16(.etc2_r8g8b8_unorm_block, &bytesOfWord(word));
    try testing.expectEqual(Rgba{ 255, 2, 2, 255 }, made[0]);
    try testing.expectEqual(Rgba{ 255, 2, 2, 255 }, made[7]);
    try testing.expectEqual(Rgba{ 2, 2, 255, 255 }, made[8]);
    try testing.expectEqual(Rgba{ 2, 2, 255, 255 }, made[15]);

    // The same flipped - bit 32: the top two rows are the first subblock.
    made = block16(.etc2_r8g8b8_unorm_block, &bytesOfWord(word | @as(u64, 1) << 32));
    try testing.expectEqual(Rgba{ 255, 2, 2, 255 }, made[0]);
    try testing.expectEqual(Rgba{ 2, 2, 255, 255 }, made[2]);

    // Differential: five bits and a delta of -4, the differential bit set
    // and table 2 for both subblocks, texel indices all 0 (+9).
    word = @as(u64, 28) << 59 | @as(u64, 4) << 56 | @as(u64, 4) << 51 | @as(u64, 2) << 48 |
        @as(u64, 3) << 43 | @as(u64, 0) << 40 | @as(u64, 2) << 37 | @as(u64, 2) << 34 | @as(u64, 1) << 33;
    made = block16(.etc2_r8g8b8_unorm_block, &bytesOfWord(word));
    // The specification's own example: (231, 33, 24) and (198, 49, 24).
    try testing.expectEqual(Rgba{ 240, 42, 33, 255 }, made[0]);
    try testing.expectEqual(Rgba{ 207, 58, 33, 255 }, made[8]);
}

test "ETC2: the T, H and planar modes of the specification's examples" {
    // T mode: red overflows, base colours (13, 1, 8) and (4, 12, 13) of 4
    // bits, distance index 5 - a distance of 32.
    var word: u64 =
        @as(u64, 31) << 59 | @as(u64, 1) << 56 | // R and Rd: 31 + 1 is outside 0..31
        @as(u64, 1) << 52 | @as(u64, 8) << 48 | // G and B of base colour 1
        @as(u64, 4) << 44 | @as(u64, 12) << 40 | @as(u64, 13) << 36 | // base colour 2
        @as(u64, 2) << 34 | @as(u64, 1) << 33 | @as(u64, 1) << 32; // da, the 1, db
    // R of base colour 1 is (R3..2 << 2) | R1..0 = (31 >> 3 & 3) << 2 | 1 = 13.
    var made = block16(.etc2_r8g8b8_unorm_block, &bytesOfWord(word));
    // Index 0 is base colour 1; 1 is base colour 2 plus 32; 2 is base
    // colour 2; 3 is base colour 2 less 32.
    try testing.expectEqual(Rgba{ 221, 17, 136, 255 }, made[0]);
    // A texel's high bit is at 16 + k and its low bit at k: texel 1 takes
    // index 1, texel 2 index 2 and texel 3 index 3.
    const indices: u64 = @as(u64, 1) << 1 | @as(u64, 1) << 18 | @as(u64, 1) << 19 | @as(u64, 1) << 3;
    made = block16(.etc2_r8g8b8_unorm_block, &bytesOfWord(word | indices));
    try testing.expectEqual(Rgba{ 100, 236, 253, 255 }, made[1]);
    try testing.expectEqual(Rgba{ 68, 204, 221, 255 }, made[2]);
    try testing.expectEqual(Rgba{ 36, 172, 189, 255 }, made[3]);

    // H mode: green overflows, base colours (13, 1, 8) and (4, 12, 13),
    // distance index 5 - da 1, db 0 and base colour 1 the larger.
    // The mode wants R + Rd inside 0..31 and G + Gd outside it: here R is
    // 13 with Rd 0, while G is 3 - bits 52 and 51, which the base colour
    // needs - with Gd -4, bit 50. Gd's other two bits are blue's B2..1, so
    // they stay 0.
    word = @as(u64, 13) << 59 | // R of base colour 1, and the mode's R
        @as(u64, 0) << 56 | @as(u64, 1) << 52 | // G3..1 and G0: green 1
        @as(u64, 1) << 51 | @as(u64, 0) << 47 | // B3 and B2..0: blue 8
        @as(u64, 4) << 48 | // Gd of the mode, bits 50..48: -4 of three bits
        @as(u64, 4) << 43 | @as(u64, 12) << 39 | @as(u64, 13) << 35 | // base colour 2
        @as(u64, 1) << 34 | @as(u64, 1) << 33 | @as(u64, 0) << 32;
    made = block16(.etc2_r8g8b8_unorm_block, &bytesOfWord(word | indices));
    try testing.expectEqual(Rgba{ 253, 49, 168, 255 }, made[0]);
    try testing.expectEqual(Rgba{ 189, 0, 104, 255 }, made[1]);
    try testing.expectEqual(Rgba{ 100, 236, 253, 255 }, made[2]);
    try testing.expectEqual(Rgba{ 36, 172, 189, 255 }, made[3]);

    // Planar mode: blue overflows. The specification's example has the
    // origin (12, 64, 62) of 676 bits, across (50, 5, 37) and down
    // (40, 112, 45).
    word = @as(u64, 12) << 57 | // R, 6 bits
        @as(u64, 64 >> 6) << 56 | @as(u64, 64 & 0x3F) << 49 | // G, 7 bits
        @as(u64, 62 >> 5) << 48 | @as(u64, 62 >> 3 & 3) << 43 | @as(u64, 62 & 7) << 39 | // B, 6 bits
        @as(u64, 50 >> 1) << 34 | @as(u64, 1) << 33 | @as(u64, 50 & 1) << 32 | // Rh
        @as(u64, 5) << 25 | @as(u64, 37) << 19 | // Gh, Bh
        @as(u64, 40) << 13 | @as(u64, 112) << 6 | @as(u64, 45); // Rv, Gv, Bv
    // The mode wants R + Rd and G + Gd inside 0..31 - 3 + 1 and 0 + 1 here -
    // and B + Bd outside: B is bits 47..43, whose top three the layout
    // leaves free, so 31 with a Bd of 3 (bits 41 and 40, blue's B2..0).
    word |= @as(u64, 7) << 45;
    made = block16(.etc2_r8g8b8_unorm_block, &bytesOfWord(word));
    try testing.expectEqual(Rgba{ 48, 129, 251, 255 }, made[0]);
    // The table in the specification, by (x, y): texel k is (k / 4, k % 4).
    try testing.expectEqual(Rgba{ 87, 99, 226, 255 }, made[4]);
    try testing.expectEqual(Rgba{ 164, 40, 175, 255 }, made[12]);
    try testing.expectEqual(Rgba{ 77, 153, 234, 255 }, made[1]);
    try testing.expectEqual(Rgba{ 250, 112, 124, 255 }, made[15]);
}

test "ETC2 with punchthrough alpha, EAC alpha and the 11-bit channels" {
    // Punchthrough, the opaque bit unset: the texel whose index is 2 is
    // clear, and the modifiers either side of the base colour are 0.
    const word: u64 = @as(u64, 31) << 59 | @as(u64, 0) << 56 | // red 31, no delta
        @as(u64, 0) << 51 | @as(u64, 0) << 48 | @as(u64, 0) << 43 | @as(u64, 0) << 40 |
        @as(u64, 0) << 37 | @as(u64, 0) << 34 | @as(u64, 0) << 33; // tables 0, not opaque
    // Texel 0 index 0 (the base colour), texel 1 index 2 (clear).
    const made = block16(.etc2_r8g8b8a1_unorm_block, &bytesOfWord(word | @as(u64, 1) << 17));
    try testing.expectEqual(Rgba{ 255, 0, 0, 255 }, made[0]);
    try testing.expectEqual(Rgba{ 0, 0, 0, 0 }, made[1]);

    // EAC alpha: the specification's example - a base of 103, table 13, a
    // multiplier of 2 and a pixel index of 3 give 83.
    var alpha_word: u64 = @as(u64, 103) << 56 | @as(u64, 2) << 52 | @as(u64, 13) << 48;
    alpha_word |= @as(u64, 3) << 45; // texel a
    var block: [16]u8 = undefined;
    block[0..8].* = bytesOfWord(alpha_word);
    // A colour word of red all over, in the individual mode.
    block[8..16].* = bytesOfWord(@as(u64, 0xF) << 60 | @as(u64, 0xF) << 56);
    const with_alpha = block16(.etc2_r8g8b8a8_unorm_block, &block);
    try testing.expectEqual(@as(u8, 83), with_alpha[0][3]);
    // The other texels take index 0, which is -1 x 2 from the base in that
    // table.
    try testing.expectEqual(@as(u8, 101), with_alpha[1][3]);

    // R11 EAC: the same numbers give 668 of 2047, whose top 8 bits are 83.
    const reds = block16(.eac_r11_unorm_block, &bytesOfWord(alpha_word));
    try testing.expectEqual(Rgba{ 83, 0, 0, 255 }, reds[0]);
    // And with a multiplier of 0, which stands for an eighth: 828 - 10.
    alpha_word = @as(u64, 103) << 56 | @as(u64, 0) << 52 | @as(u64, 13) << 48 | @as(u64, 3) << 45;
    const eighth = block16(.eac_r11_unorm_block, &bytesOfWord(alpha_word));
    try testing.expectEqual(@as(u8, (828 - 10) >> 3), eighth[0][0]);
}
