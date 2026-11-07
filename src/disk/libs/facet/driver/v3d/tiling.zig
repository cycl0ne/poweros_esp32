// SPDX-License-Identifier: MIT
//! How the TMU reads a texture: each level in the layout its size says, the
//! smallest first and the largest last, and the state that tells it where
//! they are (Mesa's v3dv_image.c, v3d_tiling.c and v3dvx_image.c).
//!
//! The TMU works out the layout of a level from its size, and where the
//! smaller levels lie from where level 0 does: none of this can be chosen.
//!   - A level no more than a microtile (64 bytes) in one direction is
//!     `lineartile`: one line of microtiles.
//!   - One no wider than 1 or 2 UIF blocks (2 x 2 microtiles) is `ublinear`:
//!     blocks in rows of that many.
//!   - Anything wider is `uif`: columns of 4 blocks, side by side, padded in
//!     height so that a column does not share the banks of the next.

const std = @import("std");

/// The most levels a texture here has: 8192 across, down to 1.
pub const most_levels = 14;

const microtile_bytes: u32 = 64;
const block_bytes: u32 = 4 * microtile_bytes;
const block_row_bytes: u32 = 4 * block_bytes;
const page_bytes: u32 = 4096;
const banks: u32 = 8;
const page_cache_bytes: u32 = page_bytes * banks;
const page_rows: u32 = page_bytes / block_row_bytes;
const page_cache_rows: u32 = page_cache_bytes / block_row_bytes;
const page_rows_and_a_half: u32 = page_rows * 3 / 2;
const page_cache_rows_less: u32 = page_cache_rows - page_rows_and_a_half;

pub const Kind = enum { lineartile, ublinear_1, ublinear_2, uif, uif_xor };

pub const Level = struct {
    kind: Kind,
    /// From the start of the texture's memory.
    offset: u32,
    width: u32,
    height: u32,
    /// Its height in pixels, padded as the layout has it.
    padded_height: u32,
    /// The rows of blocks it was padded by, if it is `uif`.
    block_pad: u32,
};

pub const Layout = struct {
    /// Bytes a pixel: 1, 2 or 4.
    pixel: u32,
    count: u32,
    levels: [most_levels]Level,
    /// All the texture takes: to be bound on `alignment`.
    bytes: u32,
};

/// What a texture's memory has to be aligned to.
pub const alignment = page_bytes;

/// A microtile is 64 bytes whatever the texel: 8 x 8 of one byte, 8 x 4
/// of two, 4 x 4 of four (Mesa's `v3d_utile_width`, `v3d_utile_height`).
fn microtileWidth(pixel: u32) u32 {
    return if (pixel <= 2) 8 else 4;
}

fn microtileHeight(pixel: u32) u32 {
    return if (pixel == 1) 8 else 4;
}

fn minify(size: u32, level: u32) u32 {
    return @max(size >> @intCast(level), 1);
}

fn alignUp(value: u32, to: u32) u32 {
    return (value + to - 1) / to * to;
}

/// The rows of blocks a `uif` level is padded by.
fn blockPad(pixel: u32, height: u32) u32 {
    const rows = height / (2 * microtileHeight(pixel));
    const into_cache = rows % page_cache_rows;
    if (into_cache == 0) return 0;
    if (into_cache < page_rows_and_a_half) return if (rows < page_cache_rows) 0 else page_rows_and_a_half - into_cache;
    if (into_cache > page_cache_rows_less) return page_cache_rows - into_cache;
    return 0;
}

/// The layout of a texture of `count` levels, whose level 0 is `width` by
/// `height`, of `pixel` bytes each.
pub fn layoutOf(pixel: u32, width: u32, height: u32, count: u32) Layout {
    var layout = Layout{ .pixel = pixel, .count = count, .levels = undefined, .bytes = 0 };
    const micro_w = microtileWidth(pixel);
    const micro_h = microtileHeight(pixel);
    const block_w = 2 * micro_w;
    const block_h = 2 * micro_h;
    // From level 2 on, sizes count from a power of two.
    const pot_width = 2 * std.math.ceilPowerOfTwoAssert(u32, minify(width, 1));
    const pot_height = 2 * std.math.ceilPowerOfTwoAssert(u32, minify(height, 1));
    var offset: u32 = 0;
    var level = count;
    while (level > 0) {
        level -= 1;
        const made = &layout.levels[level];
        made.width = minify(width, level);
        made.height = minify(height, level);
        var across = if (level < 2) made.width else minify(pot_width, level);
        var down = if (level < 2) made.height else minify(pot_height, level);
        made.block_pad = 0;
        if (across <= micro_w or down <= micro_h) {
            made.kind = .lineartile;
            across = alignUp(across, micro_w);
            down = alignUp(down, micro_h);
        } else if (across <= block_w) {
            made.kind = .ublinear_1;
            across = alignUp(across, block_w);
            down = alignUp(down, block_h);
        } else if (across <= 2 * block_w) {
            made.kind = .ublinear_2;
            across = alignUp(across, 2 * block_w);
            down = alignUp(down, block_h);
        } else {
            across = alignUp(across, 4 * block_w);
            down = alignUp(down, block_h);
            made.block_pad = blockPad(pixel, down);
            down += made.block_pad * block_h;
            made.kind = if (down / block_h % (page_cache_bytes / block_row_bytes) == 0) .uif_xor else .uif;
        }
        made.offset = offset;
        made.padded_height = down;
        var taken = across * pixel * down;
        // The hardware puts level 1 on a page if it or a smaller one could
        // be uif_xor; the smaller ones, being powers of two, then stay so.
        if (level == 1 and across > 4 * block_w and down > page_cache_rows_less * block_h) {
            taken = alignUp(taken, page_bytes);
        }
        offset += taken;
    }
    // Level 0 on a page: what comes first is what is short of it.
    const start = alignUp(layout.levels[0].offset, page_bytes) - layout.levels[0].offset;
    for (layout.levels[0..count]) |*made| made.offset += start;
    layout.bytes = offset + start;
    return layout;
}

/// Where texel (x, y) of level `level` lies, from the texture's start.
pub fn texelOffset(layout: *const Layout, level: u32, x: u32, y: u32) u32 {
    const made = &layout.levels[level];
    const pixel = layout.pixel;
    const micro_w = microtileWidth(pixel);
    const micro_h = microtileHeight(pixel);
    const inside = (x & (micro_w - 1)) * pixel + (y & (micro_h - 1)) * micro_w * pixel;
    const offset = switch (made.kind) {
        .lineartile => microtile_bytes * (x / micro_w + y / micro_h) + inside,
        .ublinear_1 => blocks(x, y, micro_w, micro_h, 1) + inside,
        .ublinear_2 => blocks(x, y, micro_w, micro_h, 2) + inside,
        .uif, .uif_xor => uif: {
            const block_x = x / (2 * micro_w);
            var block_y = y / (2 * micro_h);
            if (made.kind == .uif_xor and block_x / 4 & 1 != 0) block_y ^= 0x10;
            const rows = made.padded_height / (2 * micro_h);
            const number = block_x / 4 * ((rows - 1) * 4) + block_x + block_y * 4;
            break :uif number * block_bytes + inBlock(x, y, micro_w, micro_h) + inside;
        },
    };
    return made.offset + offset;
}

/// The offset of a microtile inside its block.
fn inBlock(x: u32, y: u32, micro_w: u32, micro_h: u32) u32 {
    return (if (y & micro_h != 0) @as(u32, 2 * microtile_bytes) else 0) + (if (x & micro_w != 0) microtile_bytes else 0);
}

fn blocks(x: u32, y: u32, micro_w: u32, micro_h: u32, columns: u32) u32 {
    const block_x = x / (2 * micro_w);
    const block_y = y / (2 * micro_h);
    return block_bytes * (block_y * columns + block_x) + inBlock(x, y, micro_w, micro_h);
}

// --- what the TMU is told ----------------------------------------------------

pub const texture_state_bytes = 24;
pub const sampler_state_bytes = 24;
/// Both go in memory on these: the low bits of their addresses in a
/// configuration parameter are other fields.
pub const texture_state_alignment = 16;
pub const sampler_state_alignment = 32;

const TEXTURE_R8: u64 = 0;
const TEXTURE_RGBA8: u64 = 4;
const TEXTURE_RGB565: u64 = 6;

const SWIZZLE_ZERO: u64 = 0;
const SWIZZLE_ONE: u64 = 1;
const SWIZZLE_RED: u64 = 2;
const SWIZZLE_GREEN: u64 = 3;
const SWIZZLE_BLUE: u64 = 4;
const SWIZZLE_ALPHA: u64 = 5;

/// What a texel holds in memory.
pub const Texels = enum {
    /// Bytes red, green, blue, alpha.
    rgba,
    /// Bytes blue, green, red, alpha.
    bgra,
    /// 16 bits, red at the top, blue at the bottom.
    rgb565,
    /// One byte of red, read as (red, 0, 0, 1) - the swizzles say the
    /// rest (since 1.48).
    r8,

    pub fn bytes(texels: Texels) u32 {
        return switch (texels) {
            .rgba, .bgra => 4,
            .rgb565 => 2,
            .r8 => 1,
        };
    }
};

/// Where each of the four channels a sample gives back comes from, as an
/// image view's swizzle names it: a channel of the colour the format reads
/// as, or a constant (since 1.120).
pub const Pick = enum { red, green, blue, alpha, zero, one };

/// Each channel from itself: a view that swizzles nothing.
pub const own_picks = [4]Pick{ .red, .green, .blue, .alpha };

/// A texture's state, into `into`: levels `base` to `last` of it, at
/// `address` on the V3D, and `depth` layers or slices `stride` bytes apart,
/// each channel from where the view's `picks` say.
pub fn writeTextureState(into: []u8, layout: *const Layout, texels: Texels, picks: [4]Pick, address: u32, base: u32, last: u32, depth: u32, stride: u32) void {
    const level_0 = &layout.levels[0];
    const base_address = address + level_0.offset;
    const strict_uif = level_0.kind == .uif or level_0.kind == .uif_xor;
    const texture_type = switch (texels) {
        .rgba, .bgra => TEXTURE_RGBA8,
        .rgb565 => TEXTURE_RGB565,
        .r8 => TEXTURE_R8,
    };
    // Which channel of the texel each of the four comes out of: a 565
    // texel has no alpha and an R8 one has red alone, so those read 1 and
    // 0, as Vulkan reads a format that is short of a channel.
    const red: u64 = if (texels == .bgra) SWIZZLE_BLUE else SWIZZLE_RED;
    const green: u64 = if (texels == .r8) SWIZZLE_ZERO else SWIZZLE_GREEN;
    const blue: u64 = switch (texels) {
        .bgra => SWIZZLE_RED,
        .r8 => SWIZZLE_ZERO,
        .rgba, .rgb565 => SWIZZLE_BLUE,
    };
    const alpha: u64 = if (texels == .rgba or texels == .bgra) SWIZZLE_ALPHA else SWIZZLE_ONE;
    // And the view's swizzle over those, as v3dv composes the format's
    // with the view's (`util_format_compose_swizzles`,
    // src/broadcom/vulkan/v3dv_image.c:828-831): a channel the view takes
    // is read from where the format keeps it, and a constant is itself.
    const own = [4]u64{ red, green, blue, alpha };
    var picked: [4]u64 = undefined;
    for (&picked, picks) |*one, pick| one.* = switch (pick) {
        .red => own[0],
        .green => own[1],
        .blue => own[2],
        .alpha => own[3],
        .zero => SWIZZLE_ZERO,
        .one => SWIZZLE_ONE,
    };
    // Bits 0 to 63: the address, the distance between arrays' worth, and
    // the width's first 6. That distance starts at bit 33 on this chip, a
    // V3D 7.1.10; on 7.1.2 it starts at 32 (Mesa's v3d_packet.xml).
    const first: u64 = @as(u64, base_address) | @as(u64, stride / 64) << 33 | @as(u64, level_0.width) << 58;
    // Bits 64 to 127.
    const second: u64 = @as(u64, level_0.width) >> 6 |
        @as(u64, level_0.height) << (72 - 64) |
        @as(u64, depth) << (86 - 64) |
        texture_type << (100 - 64) |
        @as(u64, @intFromBool(strict_uif)) << (107 - 64) |
        picked[0] << (108 - 64) |
        picked[1] << (111 - 64) |
        picked[2] << (114 - 64) |
        picked[3] << (117 - 64) |
        @as(u64, last) << (120 - 64) |
        @as(u64, base) << (124 - 64);
    // Bits 128 to 191: the planes of a video format take the same address.
    const plane: u64 = base_address >> 6;
    const third: u64 = @as(u64, if (strict_uif) level_0.block_pad else 0) |
        @as(u64, @intFromBool(level_0.kind == .uif_xor)) << (132 - 128) |
        @as(u64, @intFromBool(strict_uif)) << (134 - 128) |
        @as(u64, 1) << (136 - 128) |
        @as(u64, 1) << (137 - 128) |
        plane << (138 - 128) |
        plane << (164 - 128);
    std.mem.writeInt(u64, into[0..8], first, .little);
    std.mem.writeInt(u64, into[8..16], second, .little);
    std.mem.writeInt(u64, into[16..24], third, .little);
}

pub const Filter = enum { nearest, bilinear };
pub const Wrap = enum(u64) { repeat = 0, clamp = 1 };

/// A sampler's state, into `into`: the level the nearest to what a pixel
/// covers, as facet's own sampling chooses it.
pub fn writeSamplerState(into: []u8, filter: Filter, wrap: Wrap) void {
    const nearest: u64 = @intFromBool(filter == .nearest);
    const mip_nearest: u64 = 1 << 2;
    const max_lod: u64 = 15 << 8;
    const words: u64 = nearest | nearest << 1 | mip_nearest |
        max_lod << 20 |
        @intFromEnum(wrap) << 48 |
        @intFromEnum(wrap) << 51 |
        @intFromEnum(wrap) << 54;
    @memset(into[0..sampler_state_bytes], 0);
    std.mem.writeInt(u64, into[0..8], words, .little);
}

/// Configuration parameter 0: the state's address, and the two words of two
/// half-floats each that come back.
pub fn parameter0(state: u32) u32 {
    return state | 0b11;
}

/// Configuration parameter 1: the sampler's address, with helper pixels
/// sampling too, so that a quad's level is worked out from all of it.
pub fn parameter1(sampler: u32) u32 {
    return sampler;
}

test "the levels are in Mesa's layouts, smallest first" {
    const layout = layoutOf(4, 64, 64, 7);
    try std.testing.expectEqual(Kind.lineartile, layout.levels[6].kind);
    try std.testing.expectEqual(Kind.lineartile, layout.levels[4].kind);
    try std.testing.expectEqual(Kind.ublinear_1, layout.levels[3].kind);
    try std.testing.expectEqual(Kind.ublinear_2, layout.levels[2].kind);
    try std.testing.expectEqual(Kind.uif, layout.levels[1].kind);
    try std.testing.expectEqual(Kind.uif, layout.levels[0].kind);
    try std.testing.expectEqual(@as(u32, 0), layout.levels[0].offset % alignment);
    for (1..7) |level| try std.testing.expect(layout.levels[level].offset < layout.levels[level - 1].offset);
    try std.testing.expect(layout.bytes >= 64 * 64 * 4 + layout.levels[0].offset);
}

test "a level's texels each have a place of their own" {
    // Sizes in every layout, for each size of texel - one byte as well
    // since 1.48, whose microtile is 8 x 8 rather than 8 x 4 or 4 x 4.
    const sizes = [_][2]u32{ .{ 4, 4 }, .{ 8, 8 }, .{ 16, 16 }, .{ 32, 32 }, .{ 64, 64 }, .{ 256, 64 }, .{ 64, 256 }, .{ 128, 128 } };
    var seen: [256 * 256 * 4]bool = undefined;
    for ([_]u32{ 1, 2, 4 }) |pixel| for (sizes) |size| {
        const layout = layoutOf(pixel, size[0], size[1], 1);
        @memset(&seen, false);
        for (0..size[1]) |y| for (0..size[0]) |x| {
            const at = texelOffset(&layout, 0, @intCast(x), @intCast(y));
            try std.testing.expect(at + pixel <= layout.bytes);
            try std.testing.expectEqual(@as(u32, 0), at % pixel);
            try std.testing.expect(!seen[at]);
            seen[at] = true;
        };
    };
}

test "the UIF layout is v3d_tiling.c's" {
    const layout = layoutOf(4, 64, 64, 1);
    // A block is 8 x 8 at 4 bytes a texel; the next microtile right is 64
    // bytes on, the next down 128.
    try std.testing.expectEqual(@as(u32, 4), texelOffset(&layout, 0, 1, 0));
    try std.testing.expectEqual(@as(u32, 16), texelOffset(&layout, 0, 0, 1));
    try std.testing.expectEqual(@as(u32, 64), texelOffset(&layout, 0, 4, 0));
    try std.testing.expectEqual(@as(u32, 128), texelOffset(&layout, 0, 0, 4));
    try std.testing.expectEqual(@as(u32, 256), texelOffset(&layout, 0, 8, 0));
}

test "one byte a texel: Mesa's 8 x 8 microtile, and the TMU's R8 with the swizzles of a channel it has not" {
    // A microtile is 64 bytes whatever the texel, so one of bytes is
    // 8 x 8: the next byte right is 1 on, the next row 8, the next
    // microtile right 64 and the one below 128 (two microtiles of a
    // block, 64 each).
    const layout = layoutOf(1, 64, 64, 1);
    try std.testing.expectEqual(@as(u32, 1), texelOffset(&layout, 0, 1, 0));
    try std.testing.expectEqual(@as(u32, 8), texelOffset(&layout, 0, 0, 1));
    try std.testing.expectEqual(@as(u32, 64), texelOffset(&layout, 0, 8, 0));
    try std.testing.expectEqual(@as(u32, 128), texelOffset(&layout, 0, 0, 8));
    // A level of 64 x 64 bytes takes a quarter of what one of words takes.
    const words = layoutOf(4, 64, 64, 1);
    try std.testing.expectEqual(words.bytes - words.levels[0].offset, 4 * (layout.bytes - layout.levels[0].offset));

    var state: [texture_state_bytes]u8 = undefined;
    writeTextureState(&state, &layout, .r8, own_picks, 0x20_0000, 0, 0, 1, 0);
    const second = std.mem.readInt(u64, state[8..16], .little);
    try std.testing.expectEqual(TEXTURE_R8, second >> (100 - 64) & 0x7F);
    // Red from the texel, a green and a blue of 0 and a whole alpha: what
    // Vulkan reads of a one-channel format.
    try std.testing.expectEqual(SWIZZLE_RED, second >> (108 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_ZERO, second >> (111 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_ZERO, second >> (114 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_ONE, second >> (117 - 64) & 7);
}

test "a view's swizzle over the format's own: a channel the view takes read from where the format keeps it, a constant as itself" {
    // B8G8R8A8 viewed as its alpha, 0, 1 and its red: the alpha where it
    // is, and the red from the TMU's blue, which is where the format
    // keeps it (since 1.120).
    var state: [texture_state_bytes]u8 = undefined;
    writeTextureState(&state, &layoutOf(4, 64, 64, 1), .bgra, .{ .alpha, .zero, .one, .red }, 0x10_0000, 0, 0, 1, 0);
    var second = std.mem.readInt(u64, state[8..16], .little);
    try std.testing.expectEqual(SWIZZLE_ALPHA, second >> (108 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_ZERO, second >> (111 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_ONE, second >> (114 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_BLUE, second >> (117 - 64) & 7);
    // R8 viewed as its alpha, its green and its red twice: the alpha and
    // the green it has not got read 1 and 0, as Vulkan reads them.
    writeTextureState(&state, &layoutOf(1, 64, 64, 1), .r8, .{ .alpha, .green, .red, .red }, 0x20_0000, 0, 0, 1, 0);
    second = std.mem.readInt(u64, state[8..16], .little);
    try std.testing.expectEqual(SWIZZLE_ONE, second >> (108 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_ZERO, second >> (111 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_RED, second >> (114 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_RED, second >> (117 - 64) & 7);
}

test "the states have their fields where the packet file has them" {
    const layout = layoutOf(4, 64, 32, 1);
    var state: [texture_state_bytes]u8 = undefined;
    writeTextureState(&state, &layout, .bgra, own_picks, 0x10_0000, 0, 0, 1, 0);
    const first = std.mem.readInt(u64, state[0..8], .little);
    const second = std.mem.readInt(u64, state[8..16], .little);
    try std.testing.expectEqual(@as(u64, 0x10_0000), first & 0xFFFF_FFFF);
    const width = (first >> 58 | second << 6) & 0x3FFF;
    try std.testing.expectEqual(@as(u64, 64), width);
    try std.testing.expectEqual(@as(u64, 32), second >> (72 - 64) & 0x3FFF);
    try std.testing.expectEqual(@as(u64, 1), second >> (86 - 64) & 0x3FFF);
    try std.testing.expectEqual(TEXTURE_RGBA8, second >> (100 - 64) & 0x7F);
    try std.testing.expectEqual(SWIZZLE_BLUE, second >> (108 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_GREEN, second >> (111 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_RED, second >> (114 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_ALPHA, second >> (117 - 64) & 7);
    var sampler: [sampler_state_bytes]u8 = undefined;
    writeSamplerState(&sampler, .nearest, .clamp);
    const bits = std.mem.readInt(u64, sampler[0..8], .little);
    try std.testing.expectEqual(@as(u64, 7), bits & 7);
    try std.testing.expectEqual(@as(u64, 1), bits >> 48 & 7);
    try std.testing.expectEqual(@as(u64, 15 << 8), bits >> 20 & 0xFFF);
}
