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
    try testing.expectError(error.BadSize, Texture.bytes(.rgba8888, 6, 4, 1));
    try testing.expectError(error.BadSize, Texture.bytes(.rgba8888, 8, 0, 1));
    try testing.expectError(error.BadSize, Texture.bytes(.rgba8888, 8, 4, 0));
    try testing.expectError(error.BadSize, Texture.bytes(.rgba8888, 8, 4, 5));

    var memory: [64]u64 = undefined;
    const made = try Texture.init(.rgba8888, 8, 4, 3, @ptrCast(&memory));
    for ([_]u32{ 0, 32 * 8, 48 * 8 }, made.layout[0..3]) |start, level| try testing.expectEqual(start, level.start);
    try testing.expectEqual(@as(u32, 8), made.width(0));
    try testing.expectEqual(@as(u32, 1), made.height(2));
    // (5, 2) is in the second block, its third row, its second column.
    try testing.expectEqual(@as(u32, 16 + 2 * 4 + 1), made.index(0, 5, 2));
    try testing.expectEqual(@as(u32, 48 + 1), made.index(2, 1, 0));
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
