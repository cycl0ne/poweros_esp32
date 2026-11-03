// SPDX-License-Identifier: MPL-2.0
//! Host tests of textures: their sizes and blocks, and samples read from
//! them.

const std = @import("std");
const texture = @import("sdk").facet.texture;
const testing = std.testing;

const Texture = texture.Texture;

/// A texel of its own for every (x, y), in 8888.
fn texelAt(x: u32, y: u32) u32 {
    return 0xFF00_0000 | x << 16 | y << 8 | (x ^ y);
}

/// The same in 565: x in red, y in green, the low bits of both in blue.
fn texelAt565(x: u32, y: u32) u32 {
    return x << 11 | y << 5 | ((x + y) & 0x1F);
}

fn sampleAt(comptime sampling: texture.Sampling, made: *const Texture, lod: u32, u: f32, v: f32) u32 {
    return texture.sample(sampling, made, &made.layout[lod], u, v);
}

test "a texture's size and levels are checked, each level laid out in blocks of 4 x 4" {
    // 8 x 4 is two blocks, 4 x 2 and 2 x 1 a whole one each.
    try testing.expectEqual(@as(usize, (32 + 16 + 16) * 8), try Texture.bytes(.rgba8888, 8, 4, 3));
    try testing.expectEqual(@as(usize, (32 + 16 + 16 + 16) * 2), try Texture.bytes(.rgb565, 8, 4, 4));
    try testing.expectError(error.BadSize, Texture.bytes(.rgba8888, 8, 0, 1));
    try testing.expectError(error.BadSize, Texture.bytes(.rgba8888, 8, 4, 0));
    try testing.expectError(error.BadSize, Texture.bytes(.rgba8888, 8, 4, 5));
    try testing.expectError(error.BadSize, Texture.bytes(.rgba8888, 1 << 16, 4, 1));

    // Any size, since 1.42: the blocks of a level are laid out by the next
    // power of two across - 6 as 8, so two blocks - and by the level's own
    // height down. 6 x 5 is 2 by 2 blocks, and its second level, 3 x 2, one.
    try testing.expectEqual(@as(usize, (2 * 1 * 16) * 8), try Texture.bytes(.rgba8888, 6, 4, 1));
    try testing.expectEqual(@as(usize, (2 * 2 * 16 + 16) * 8), try Texture.bytes(.rgba8888, 6, 5, 2));
    // As many levels as halving the longer side gives: 100 gives seven.
    try testing.expectError(error.BadSize, Texture.bytes(.rgba8888, 100, 60, 8));
    _ = try Texture.bytes(.rgba8888, 100, 60, 7);

    var memory: [64]u64 = undefined;
    const made = try Texture.init(.rgba8888, 8, 4, 3, @ptrCast(&memory));
    for ([_]u32{ 0, 32 * 8, 48 * 8 }, made.layout[0..3]) |start, level| try testing.expectEqual(start, level.start);
    try testing.expectEqual(@as(u32, 8), made.width(0));
    try testing.expectEqual(@as(u32, 1), made.height(2));
    // (5, 2) is in the second block, its third row, its second column.
    try testing.expectEqual(@as(u32, 16 + 2 * 4 + 1), made.index(0, 5, 2));
    try testing.expectEqual(@as(u32, 48 + 1), made.index(2, 1, 0));
}

test "a texture of any size: its levels halved, its texels where its width's padding says" {
    var memory: [16 * 16]u64 = undefined;
    const made = try Texture.init(.rgba8888, 6, 5, 2, @ptrCast(&memory));
    try testing.expectEqual(@as(u32, 6), made.width(0));
    try testing.expectEqual(@as(u32, 5), made.height(0));
    try testing.expectEqual(@as(u32, 3), made.width(1));
    try testing.expectEqual(@as(u32, 2), made.height(1));
    // A level past the last reads as the last.
    try testing.expectEqual(@as(u32, 3), made.width(7));
    // Level 1 starts where level 0's two by two blocks end.
    try testing.expectEqual(@as(u32, 0), made.layout[0].start);
    try testing.expectEqual(@as(u32, 2 * 2 * 16 * 8), made.layout[1].start);
    // (5, 2) is in the second block across, its third row, its second
    // column: the blocks are laid out by 8 across, the width padded.
    try testing.expectEqual(@as(u32, 16 + 2 * 4 + 1), made.index(0, 5, 2));
    // Neither level tiles by masking; a texture of two powers of two does.
    try testing.expect(!made.layout[0].tiles and !made.layout[1].tiles);
    const square = try Texture.init(.rgba8888, 8, 4, 2, @ptrCast(&memory));
    try testing.expect(square.layout[0].tiles and square.layout[1].tiles);

    // Every texel of every level is its own, and none of level 1 is where
    // one of level 0 lies.
    var full = try Texture.init(.rgba8888, 6, 5, 2, @ptrCast(&memory));
    @memset(std.mem.asBytes(&memory), 0);
    for (0..2) |lod| for (0..full.height(@intCast(lod))) |y| for (0..full.width(@intCast(lod))) |x| {
        full.put(@intCast(lod), @intCast(x), @intCast(y), texelAt(@intCast(x + 16 * lod), @intCast(y)));
    };
    for (0..2) |lod| for (0..full.height(@intCast(lod))) |y| for (0..full.width(@intCast(lod))) |x| {
        try testing.expectEqual(texelAt(@intCast(x + 16 * lod), @intCast(y)), full.peek(@intCast(lod), @intCast(x), @intCast(y)));
    };
}

test "a texture whose sides are not powers of two: sampled, clamped and wrapped" {
    const across = 6;
    const down = 5;
    var picture: [across * down]u32 = undefined;
    for (0..down) |y| for (0..across) |x| {
        picture[y * across + x] = texelAt(@intCast(x), @intCast(y));
    };
    var memory: [16 * 16]u64 = undefined;
    var made = try Texture.init(.rgba8888, across, down, 1, @ptrCast(&memory));
    made.load(0, @ptrCast(&picture), across * 4);
    for (0..down) |y| for (0..across) |x| {
        try testing.expectEqual(picture[y * across + x], made.peek(0, @intCast(x), @intCast(y)));
    };

    // The nearest texel of each, by both ways round the edges: a
    // coordinate is 0 to 1 across the texture, whatever its size.
    const nearest_wrap = texture.Sampling{ .filter = .nearest, .address = .wrap };
    const nearest_clamp = texture.Sampling{ .filter = .nearest, .address = .clamp };
    for (0..down) |y| for (0..across) |x| {
        const u = (@as(f32, @floatFromInt(x)) + 0.5) / across;
        const v = (@as(f32, @floatFromInt(y)) + 0.5) / down;
        const want = picture[y * across + x];
        try testing.expectEqual(want, sampleAt(nearest_clamp, &made, 0, u, v));
        try testing.expectEqual(want, sampleAt(nearest_wrap, &made, 0, u, v));
        // The texture again, forwards and backwards: a division, not a
        // mask, so it comes round at the texture's own size.
        try testing.expectEqual(want, sampleAt(nearest_wrap, &made, 0, u + 3, v + 1));
        try testing.expectEqual(want, sampleAt(nearest_wrap, &made, 0, u - 2, v - 4));
    };
    // Clamped, a coordinate past the edge reads the edge's texel.
    try testing.expectEqual(picture[0], sampleAt(nearest_clamp, &made, 0, -3, -1));
    try testing.expectEqual(picture[down * across - 1], sampleAt(nearest_clamp, &made, 0, 4, 2));

    // Filtered: the four texels round the point, which for a point in the
    // last column and row are the first ones again when it wraps, and the
    // same ones twice when it clamps.
    const smooth_wrap = texture.Sampling{ .filter = .bilinear, .address = .wrap };
    const smooth_clamp = texture.Sampling{ .filter = .bilinear, .address = .clamp };
    const last_u: f32 = (across - 0.5) / @as(f32, across);
    const last_v: f32 = (down - 0.5) / @as(f32, down);
    try testing.expectEqual(picture[(down - 1) * across + across - 1], sampleAt(smooth_clamp, &made, 0, last_u, last_v));
    const corner = mixedFour(.{
        picture[(down - 1) * across + across - 1],
        picture[(down - 1) * across],
        picture[across - 1],
        picture[0],
    }, 128, 128);
    try testing.expectEqual(corner, sampleAt(smooth_wrap, &made, 0, last_u + 0.5 / @as(f32, across), last_v + 0.5 / @as(f32, down)));
}

/// The four texels round a point - top left, top right, bottom left,
/// bottom right - mixed as `sampleAt` mixes them: by weights of 256 from
/// how far the point is across the texel and down it, each channel on its
/// own, and nothing rounded.
fn mixedFour(corners: [4]u32, across: u32, down: u32) u32 {
    const both = across * down >> 8;
    const weights = [4]u32{ 256 + both - across - down, across - both, down - both, both };
    var out: u32 = 0;
    inline for (0..4) |channel| {
        const shift: u5 = @as(u5, channel) * 8;
        var sum: u32 = 0;
        for (corners, weights) |texel, weight| sum += (texel >> shift & 0xFF) * weight;
        out |= (sum >> 8 & 0xFF) << shift;
    }
    return out;
}

test "a picture loaded is read back, texel for texel, by the nearest sample" {
    const side = 16;
    var picture: [side * side]u32 = undefined;
    var picture565: [side * side]u16 = undefined;
    for (0..side) |y| for (0..side) |x| {
        picture[y * side + x] = texelAt(@intCast(x), @intCast(y));
        picture565[y * side + x] = @intCast(texelAt565(@intCast(x), @intCast(y)));
    };
    var memory: [side * side]u64 = undefined;
    var memory565: [side * side]u16 = undefined;
    var made = try Texture.init(.rgba8888, side, side, 1, @ptrCast(&memory));
    var made565 = try Texture.init(.rgb565, side, side, 1, @ptrCast(&memory565));
    made.load(0, @ptrCast(&picture), side * 4);
    made565.load(0, @ptrCast(&picture565), side * 2);
    // Kept in blocks, not in rows, and 8888 spread.
    try testing.expect(memory[4] != texture.spread(picture[4]));
    try testing.expectEqual(texture.spread(picture[side]), memory[4]);
    try testing.expectEqual(@as(u64, 0x0080_0020_0040_0010), texture.spread(0x8040_2010));
    try testing.expectEqual(@as(u32, 0x8040_2010), texture.gather(0x0080_0020_0040_0010));
    for (0..side) |y| for (0..side) |x| {
        const u = (@as(f32, @floatFromInt(x)) + 0.5) / side;
        const v = (@as(f32, @floatFromInt(y)) + 0.5) / side;
        try testing.expectEqual(picture[y * side + x], sampleAt(.{ .filter = .nearest }, &made, 0, u, v));
        const wide = texture.widen(picture565[y * side + x]);
        try testing.expectEqual(wide, sampleAt(.{ .format = .rgb565, .filter = .nearest }, &made565, 0, u, v));
    };
    // 565 widened: each channel's top bits again below.
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), texture.widen(0xFFFF));
    try testing.expectEqual(@as(u32, 0xFF08_0C10), texture.widen(1 << 11 | 3 << 5 | 2));
}

test "past the edges a texture wraps round or holds its edge" {
    const side = 8;
    var memory: [side * side]u64 = undefined;
    var made = try Texture.init(.rgba8888, side, side, 1, @ptrCast(&memory));
    for (0..side) |y| for (0..side) |x| made.put(0, @intCast(x), @intCast(y), texelAt(@intCast(x), @intCast(y)));
    const wrap = texture.Sampling{ .filter = .nearest, .address = .wrap };
    const clamp = texture.Sampling{ .filter = .nearest, .address = .clamp };
    // A quarter before the left edge is texel 6 round the other side.
    try testing.expectEqual(texelAt(6, 1), sampleAt(wrap, &made, 0, -0.25, 1.5 / @as(f32, side)));
    try testing.expectEqual(texelAt(0, 1), sampleAt(clamp, &made, 0, -0.25, 1.5 / @as(f32, side)));
    try testing.expectEqual(texelAt(0, 7), sampleAt(wrap, &made, 0, 1.01, 2.99));
    try testing.expectEqual(texelAt(7, 7), sampleAt(clamp, &made, 0, 1.01, 2.99));
    // Far past any edge, and a NaN, still read a texel.
    try testing.expectEqual(texelAt(7, 0), sampleAt(clamp, &made, 0, 1e30, -1e30));
    _ = sampleAt(wrap, &made, 0, std.math.nan(f32), std.math.inf(f32));
}

test "bilinear mixes the four texels round a point, by how near it is to each" {
    var memory: [16]u64 = undefined;
    var made = try Texture.init(.rgba8888, 2, 2, 1, @ptrCast(&memory));
    made.put(0, 0, 0, 0xFF00_0000);
    made.put(0, 1, 0, 0xFFFF_0000);
    made.put(0, 0, 1, 0x0000_FF00);
    made.put(0, 1, 1, 0x0000_00FF);
    const clamp = texture.Sampling{ .filter = .bilinear, .address = .clamp };
    const wrap = texture.Sampling{ .filter = .bilinear, .address = .wrap };
    // On a texel's centre, that texel.
    try testing.expectEqual(@as(u32, 0xFFFF_0000), sampleAt(clamp, &made, 0, 0.75, 0.25));
    // Between all four, a quarter of each.
    try testing.expectEqual(@as(u32, 0x7F3F_3F3F), sampleAt(clamp, &made, 0, 0.5, 0.5));
    // Halfway between the top two.
    try testing.expectEqual(@as(u32, 0xFF7F_0000), sampleAt(clamp, &made, 0, 0.5, 0.25));
    // The top left's centre less half a texel: clamped, the texel alone;
    // wrapped, halfway to the top right round the edge.
    try testing.expectEqual(@as(u32, 0xFF00_0000), sampleAt(clamp, &made, 0, 0.0, 0.25));
    try testing.expectEqual(@as(u32, 0xFF7F_0000), sampleAt(wrap, &made, 0, 0.0, 0.25));
}

test "the level is the one whose texels are as large as a pixel's step" {
    var memory: [(64 * 64 + 32 * 32 + 16 * 16 + 8 * 8)]u64 = undefined;
    const made = try Texture.init(.rgba8888, 64, 64, 4, @ptrCast(&memory));
    const Case = struct { step: f32, level: u32 };
    // A level changes where the step is a power of two times the root of
    // two; the last one the texture has holds anything larger.
    for ([_]Case{
        .{ .step = 0, .level = 0 },
        .{ .step = 0.5, .level = 0 },
        .{ .step = 1, .level = 0 },
        .{ .step = 1.3, .level = 0 },
        .{ .step = 1.5, .level = 1 },
        .{ .step = 2, .level = 1 },
        .{ .step = 2.7, .level = 1 },
        .{ .step = 3, .level = 2 },
        .{ .step = 4, .level = 2 },
        .{ .step = 6, .level = 3 },
        .{ .step = 1000, .level = 3 },
    }) |case| {
        try testing.expectEqual(case.level, texture.levelFor(&made, case.step, 0, 0, 0.1));
        try testing.expectEqual(case.level, texture.levelFor(&made, 0.1, 0, 0, case.step));
        // A step aslant, the same length.
        try testing.expectEqual(case.level, texture.levelFor(&made, case.step * 0.6, case.step * 0.8, 0, 0));
    }
    try testing.expectEqual(@as(u32, 3), texture.levelFor(&made, std.math.nan(f32), 0, 0, 0));
    try testing.expectEqual(@as(u32, 3), texture.levelFor(&made, std.math.inf(f32), 0, 0, 0));
}

// --- sampling through a sampler ---------------------------------------------

const Sampler = texture.Sampler;
const Point = texture.Point;

/// A texture of `levels` levels, every texel of each one colour: what the
/// level a sample falls on can be read off from.
fn levelled(memory: []u64, side: u32, levels: u32, colors: []const u32) !Texture {
    var made = try Texture.init(.rgba8888, side, side, levels, @ptrCast(memory.ptr));
    for (colors, 0..) |color, lod| {
        for (0..made.height(@intCast(lod))) |y| for (0..made.width(@intCast(lod))) |x| {
            made.put(@intCast(lod), @intCast(x), @intCast(y), color);
        };
    }
    return made;
}

test "a sampler reads past the edges as each of its wraps says" {
    const side = 4;
    var memory: [side * side]u64 = undefined;
    var made = try Texture.init(.rgba8888, side, side, 1, @ptrCast(&memory));
    for (0..side) |y| for (0..side) |x| {
        made.put(0, @intCast(x), @intCast(y), texelAt(@intCast(x), @intCast(y)));
    };
    // Half a texel to the left of the first column, and in the first row:
    // whatever the wrap puts there.
    const point = Point{ .u = -0.1, .v = 0.1 };
    const Case = struct { wrap: texture.Wrap, texel: u32 };
    for ([_]Case{
        .{ .wrap = .repeat, .texel = texelAt(side - 1, 0) },
        .{ .wrap = .mirrored_repeat, .texel = texelAt(0, 0) },
        .{ .wrap = .clamp_to_edge, .texel = texelAt(0, 0) },
        .{ .wrap = .clamp_to_border, .texel = 0xFF00_FF00 },
    }) |case| {
        const sampler = Sampler{ .mag_filter = .nearest, .min_filter = .nearest, .wrap = @splat(case.wrap), .border = 0xFF00_FF00 };
        try testing.expectEqual(case.texel, texture.sampleBy(&made, &sampler, 0, point));
    }
    // Mirrored: the texture again turned round, so the column two to the
    // left of the first is the second.
    const mirror = Sampler{ .mag_filter = .nearest, .min_filter = .nearest, .wrap = @splat(.mirrored_repeat) };
    try testing.expectEqual(texelAt(1, 0), texture.sampleBy(&made, &mirror, 0, .{ .u = -0.4, .v = 0.1 }));
    // And at the far side, the last column again.
    try testing.expectEqual(texelAt(side - 1, 0), texture.sampleBy(&made, &mirror, 0, .{ .u = 1.1, .v = 0.1 }));
}

test "a sampler's level: the nearest, or the two round it mixed, with the bias and the clamp it was given" {
    const side = 4;
    const red: u32 = 0xFFFF_0000;
    const blue: u32 = 0xFF00_00FF;
    const green: u32 = 0xFF00_FF00;
    // A level smaller than a block of 4 x 4 takes a whole one all the same.
    var memory: [3 * 4 * 4]u64 = undefined;
    const made = try levelled(&memory, side, 3, &.{ red, blue, green });
    // A step of the root of two texels is level 0.5, halfway between the
    // first level and the second.
    const half = Point{ .u = 0.5, .v = 0.5, .du_dx = @sqrt(2.0) / @as(f32, side), .dv_dy = 0 };
    try testing.expectApproxEqAbs(@as(f32, 0.5), texture.levelOf(&made, half), 1e-5);

    const nearest = Sampler{ .mag_filter = .nearest, .min_filter = .nearest };
    try testing.expectEqual(blue, texture.sampleBy(&made, &nearest, 0, half));
    var linear = nearest;
    linear.mipmap = .linear;
    // Red and blue, half of each.
    try testing.expectEqual(@as(u32, 0xFF80_0080), texture.sampleBy(&made, &linear, 0, half));

    // The bias moves the level; the clamp holds it.
    var biased = nearest;
    biased.lod_bias = 1;
    try testing.expectEqual(green, texture.sampleBy(&made, &biased, 0, half));
    var held = biased;
    held.max_lod = 0;
    try testing.expectEqual(red, texture.sampleBy(&made, &held, 0, half));
    var least = nearest;
    least.min_lod = 2;
    try testing.expectEqual(green, texture.sampleBy(&made, &least, 0, .{ .u = 0.5, .v = 0.5 }));
    // Without a step there is no level: the first, and the magnifying
    // filter.
    try testing.expectEqual(red, texture.sampleBy(&made, &linear, 0, .{ .u = 0.5, .v = 0.5 }));
}

test "anisotropy spreads its samples along the longer axis, at the shorter one's level" {
    const side = 8;
    var memory: [side * side]u64 = undefined;
    var made = try Texture.init(.rgba8888, side, side, 1, @ptrCast(&memory));
    const black: u32 = 0xFF00_0000;
    const white: u32 = 0xFFFF_FFFF;
    for (0..side) |y| for (0..side) |x| {
        made.put(0, @intCast(x), @intCast(y), if (x < side / 2) black else white);
    };
    // A pixel that covers the whole texture across and one texel down.
    const point = Point{ .u = 0.5, .v = 0.5, .du_dx = 1, .dv_dy = 1.0 / @as(f32, side) };
    const one = Sampler{ .mag_filter = .nearest, .min_filter = .nearest };
    // One sample at the middle, in the white half, whatever the level.
    try testing.expectEqual(white, texture.sampleBy(&made, &one, 0, point));
    var wide = one;
    wide.anisotropy = 8;
    // Eight samples across the row: four black, four white.
    try testing.expectEqual(@as(u32, 0xFF80_8080), texture.sampleBy(&made, &wide, 0, point));
    // More than the texture asks for is held to what the axes say.
    wide.anisotropy = texture.most_taps;
    try testing.expectEqual(@as(u32, 0xFF80_8080), texture.sampleBy(&made, &wide, 0, point));
}

test "a shadow sample compares what it read with its reference, and mixes what passed" {
    const side = 4;
    var memory: [side * side]u64 = undefined;
    var made = try Texture.init(.rgba8888, side, side, 1, @ptrCast(&memory));
    // The red channel is what is compared: 0 on the left, 1 on the right.
    for (0..side) |y| for (0..side) |x| {
        made.put(0, @intCast(x), @intCast(y), if (x < side / 2) 0xFF00_0000 else 0xFFFF_0000);
    };
    const white: u32 = 0xFFFF_FFFF;
    const black: u32 = 0xFF00_0000;
    var sampler = Sampler{ .mag_filter = .nearest, .min_filter = .nearest, .compare = .less };
    // 0.5 is nearer than 1 and farther than 0.
    try testing.expectEqual(white, texture.sampleBy(&made, &sampler, 0, .{ .u = 0.8, .v = 0.5, .reference = 0.5 }));
    try testing.expectEqual(black, texture.sampleBy(&made, &sampler, 0, .{ .u = 0.2, .v = 0.5, .reference = 0.5 }));
    sampler.compare = .greater;
    try testing.expectEqual(black, texture.sampleBy(&made, &sampler, 0, .{ .u = 0.8, .v = 0.5, .reference = 0.5 }));
    // Filtered, what is mixed is what passed, not what was read: two of
    // the four texels round the point are nearer than the reference.
    sampler.compare = .less;
    sampler.mag_filter = .bilinear;
    sampler.wrap = @splat(.clamp_to_edge);
    try testing.expectEqual(@as(u32, 0xFF80_8080), texture.sampleBy(&made, &sampler, 0, .{ .u = 0.5, .v = 0.125, .reference = 0.5 }));
}

/// A BC1 block: two endpoint colours of 565 and two bits for each of the
/// sixteen texels, the first texel's lowest.
fn bc1Block(low: u16, high: u16, picks: u32) [8]u8 {
    var made: [8]u8 = undefined;
    std.mem.writeInt(u16, made[0..2], low, .little);
    std.mem.writeInt(u16, made[2..4], high, .little);
    std.mem.writeInt(u32, made[4..8], picks, .little);
    return made;
}

test "a compressed texture is kept in its blocks and decoded as it is sampled" {
    // A block is 8 bytes of BC1 and 16 of the rest, whatever a texel of
    // 8888 would take: 8 x 8 is four blocks.
    try testing.expectEqual(@as(usize, 4 * 8), try Texture.bytes(.bc1, 8, 8, 1));
    try testing.expectEqual(@as(usize, 4 * 16), try Texture.bytes(.bc3, 8, 8, 1));
    try testing.expect(texture.Format.bc2.compressed());
    try testing.expect(!texture.Format.rgba8888.compressed());

    var memory: [16]u64 = undefined;
    var made = try Texture.init(.bc1, 8, 8, 1, @ptrCast(&memory));
    const red: u16 = 0xF800;
    const blue: u16 = 0x001F;
    // The top left block: red and blue its endpoints, its first texel the
    // one and its second the other, the rest red.
    made.putBlock(0, 0, 0, 0, &bc1Block(red, blue, 1 << 2));
    // Blue all over, and white all over, from endpoints of one colour.
    made.putBlock(0, 0, 4, 0, &bc1Block(blue, blue, 0));
    made.putBlock(0, 0, 0, 4, &bc1Block(0xFFFF, 0xFFFF, 0));
    // Black and white in that order punch through: the third colour is
    // halfway and the fourth clear, which every texel here picks.
    made.putBlock(0, 0, 4, 4, &bc1Block(0x0000, 0xFFFF, 0xFFFF_FFFF));

    // A texel at a time, out of the block it lies in.
    try testing.expectEqual(@as(u32, 0xFFFF_0000), made.colorAt(0, 0, 0, 0));
    try testing.expectEqual(@as(u32, 0xFF00_00FF), made.colorAt(0, 0, 1, 0));
    try testing.expectEqual(@as(u32, 0xFFFF_0000), made.colorAt(0, 0, 3, 3));
    try testing.expectEqual(@as(u32, 0xFF00_00FF), made.colorAt(0, 0, 4, 0));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), made.colorAt(0, 0, 0, 4));
    // Clear, and black with it: what a GPU reads of a punched-through texel.
    try testing.expectEqual(@as(u32, 0), made.colorAt(0, 0, 5, 5));

    const nearest = texture.Sampling{ .format = .bc1, .filter = .nearest };
    const clamp = texture.Sampling{ .format = .bc1, .filter = .bilinear, .address = .clamp };
    try testing.expectEqual(@as(u32, 0xFFFF_0000), sampleAt(nearest, &made, 0, 1.0 / 16.0, 1.0 / 16.0));
    try testing.expectEqual(@as(u32, 0xFF00_00FF), sampleAt(nearest, &made, 0, 3.0 / 16.0, 1.0 / 16.0));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), sampleAt(nearest, &made, 0, 1.0 / 16.0, 9.0 / 16.0));
    // Two texels of one block mixed: the block is decoded once.
    try testing.expectEqual(@as(u32, 0xFF7F_007F), sampleAt(clamp, &made, 0, 1.0 / 8.0, 1.0 / 16.0));
    // Two texels in blocks beside each other, which takes both blocks:
    // the red of the first and the blue of the second.
    try testing.expectEqual(@as(u32, 0xFF7F_007F), sampleAt(clamp, &made, 0, 0.5, 1.0 / 16.0));
}

test "a BC2 block's four bits of alpha and a BC3 block's ramp of it" {
    var memory: [16]u64 = undefined;
    var two = try Texture.init(.bc2, 4, 4, 1, @ptrCast(&memory));
    var block: [16]u8 = undefined;
    // Four bits a texel, the first texel's lowest: 0, 1, ... up the block.
    var alphas: u64 = 0;
    for (0..16) |k| alphas |= @as(u64, @intCast(k)) << @intCast(k * 4);
    std.mem.writeInt(u64, block[0..8], alphas, .little);
    block[8..16].* = bc1Block(0xF800, 0xF800, 0);
    two.putBlock(0, 0, 0, 0, &block);
    // 0 to 15 of 15, each repeated into its low bits: 0x00, 0x11, ... 0xFF.
    for (0..4) |y| for (0..4) |x| {
        const k = y * 4 + x;
        const alpha: u32 = @intCast(k * 0x11);
        try testing.expectEqual(alpha << 24 | 0x00FF_0000, two.colorAt(0, 0, @intCast(x), @intCast(y)));
    };

    var three = try Texture.init(.bc3, 4, 4, 1, @ptrCast(&memory));
    // Endpoints 240 and 60 in that order: six values between them, three
    // bits picking one. Texel 0 takes the first, texel 1 the second, texel
    // 2 the first value between.
    block[0] = 240;
    block[1] = 60;
    var picks: u64 = 1 << 3 | @as(u64, 2) << 6;
    for (0..6) |k| block[2 + k] = @intCast(picks >> @intCast(k * 8) & 0xFF);
    picks = 0;
    three.putBlock(0, 0, 0, 0, &block);
    try testing.expectEqual(@as(u32, 0xF0FF_0000), three.colorAt(0, 0, 0, 0));
    try testing.expectEqual(@as(u32, 0x3CFF_0000), three.colorAt(0, 0, 1, 0));
    // (6 x 240 + 1 x 60 + 3) / 7 = 214.
    try testing.expectEqual(@as(u32, 0xD6FF_0000), three.colorAt(0, 0, 2, 0));
}
