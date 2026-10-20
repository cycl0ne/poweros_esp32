// SPDX-License-Identifier: MIT
//! A material's picture made into a texture's levels: facet.library takes
//! sides that are powers of two and the levels below the first from
//! whoever makes the texture (sdk.facet.texture).
//!
//! The picture is scaled to the nearest power of two each way - no more
//! than `most_side` - each texel the mix of the four pixels round its
//! centre, and each level after the first is the one before halved, a
//! texel the mean of four. They are staged one after the other, a texel
//! 0xAARRGGBB in four bytes, b8g8r8a8 as an image of that format is
//! copied from; `regions` says where each level is, for the copy into
//! its level. model.datatype stages a picture as it is handed over, and
//! its process copies the levels in once it has a device.

const std = @import("std");
const facet = @import("sdk").facet;

/// The largest side a texture is given: 1024 x 1024 in 8888 takes 8 MiB
/// spread, the levels below a third more.
pub const most_side = 1024;

/// The most levels a texture of `most_side` has.
pub const most_levels = std.math.log2_int(u32, most_side) + 1;

/// A texture's size and levels for a picture of `width` x `height`.
pub const Shape = struct {
    width: u32,
    height: u32,
    levels: u32,

    pub fn of(width: u32, height: u32) Shape {
        const across = side(width);
        const down = side(height);
        return .{ .width = across, .height = down, .levels = std.math.log2_int(u32, @max(across, down)) + 1 };
    }

    /// The bytes all its levels take staged.
    pub fn bytes(shape: Shape) usize {
        var total: usize = 0;
        for (0..shape.levels) |level| total += @as(usize, levelSide(shape.width, level)) * levelSide(shape.height, level) * 4;
        return total;
    }
};

/// The power of two nearest `pixels`, between 1 and `most_side`: the one
/// above when `pixels` is at least half as much again as the one below.
fn side(pixels: u32) u32 {
    if (pixels <= 1) return 1;
    const below = @as(u32, 1) << std.math.log2_int(u32, pixels);
    const nearest = if (pixels - below >= below / 2) below * 2 else below;
    return @min(nearest, most_side);
}

/// A side of level `level`: halved, down to 1.
fn levelSide(full: u32, level: usize) u32 {
    return @max(full >> @intCast(level), 1);
}

/// The picture, `width` x `height` pixels 0xAARRGGBB `pitch` bytes a row
/// apart, staged into `into` (`shape.bytes()` of it) as `shape` says.
pub fn stage(pixels: [*]const u8, width: u32, height: u32, pitch: usize, shape: Shape, into: [*]u8) void {
    const first: [*]u32 = @ptrCast(@alignCast(into));
    scale(pixels, width, height, pitch, first, shape.width, shape.height);
    var at: usize = @as(usize, shape.width) * shape.height * 4;
    var above = first;
    for (1..shape.levels) |level| {
        const across = levelSide(shape.width, level);
        const down = levelSide(shape.height, level);
        const here: [*]u32 = @ptrCast(@alignCast(into + at));
        halve(above, levelSide(shape.width, level - 1), levelSide(shape.height, level - 1), here, across, down);
        at += @as(usize, across) * down * 4;
        above = here;
    }
}

/// Where `stage` put each level of `shape`: the regions that copy them
/// from a buffer into an image's levels.
pub fn regions(shape: Shape) [most_levels]facet.BufferImageCopy {
    var made: [most_levels]facet.BufferImageCopy = undefined;
    var at: usize = 0;
    for (0..shape.levels) |level| {
        const across = levelSide(shape.width, level);
        const down = levelSide(shape.height, level);
        made[level] = .{ .buffer_offset = at, .image_subresource = .{ .mip_level = @intCast(level) }, .image_extent = .{ .width = across, .height = down } };
        at += @as(usize, across) * down * 4;
    }
    return made;
}

/// The picture scaled to `across` x `down`: each texel the four pixels
/// round its centre, mixed by how near it is to each.
fn scale(pixels: [*]const u8, width: u32, height: u32, pitch: usize, into: [*]u32, across: u32, down: u32) void {
    // 16.16 steps through the picture, from each texel's centre.
    const step_x: u64 = (@as(u64, width) << 16) / across;
    const step_y: u64 = (@as(u64, height) << 16) / down;
    for (0..down) |ty| {
        const y = centred(ty, step_y, height);
        const upper: [*]const u32 = @ptrCast(@alignCast(pixels + y.first * pitch));
        const lower: [*]const u32 = @ptrCast(@alignCast(pixels + y.second * pitch));
        for (0..across) |tx| {
            const x = centred(tx, step_x, width);
            const top = mix(upper[x.first], upper[x.second], x.weight);
            const bottom = mix(lower[x.first], lower[x.second], x.weight);
            into[ty * across + tx] = mix(top, bottom, y.weight);
        }
    }
}

/// Where texel `t`'s centre falls among `count` pixels `step` apart in
/// 16.16: the pixel at or before it, the one after, and how far towards
/// the second it lies, 0 to 256.
fn centred(t: usize, step: u64, count: u32) struct { first: usize, second: usize, weight: u32 } {
    const centre = @as(u64, t) * step + step / 2;
    const at = if (centre >= 1 << 15) centre - (1 << 15) else 0;
    const first: usize = @min(at >> 16, count - 1);
    return .{ .first = first, .second = @min(first + 1, count - 1), .weight = @intCast(at >> 8 & 0xFF) };
}

/// `a` towards `b` by `weight` of 256, each channel.
fn mix(a: u32, b: u32, weight: u32) u32 {
    var out: u32 = 0;
    inline for (0..4) |k| {
        const shift = 8 * k;
        const from = a >> shift & 0xFF;
        const to = b >> shift & 0xFF;
        out |= ((from * (256 - weight) + to * weight + 128) >> 8) << shift;
    }
    return out;
}

/// A level halved into the next: each texel the mean of the four above
/// it, or of two where a side is 1 already.
fn halve(above: [*]const u32, width: u32, height: u32, into: [*]u32, across: u32, down: u32) void {
    for (0..down) |y| for (0..across) |x| {
        const x0 = @min(x * 2, width - 1);
        const x1 = @min(x * 2 + 1, width - 1);
        const y0 = @min(y * 2, height - 1);
        const y1 = @min(y * 2 + 1, height - 1);
        const four = [4]u32{ above[y0 * width + x0], above[y0 * width + x1], above[y1 * width + x0], above[y1 * width + x1] };
        var out: u32 = 0;
        inline for (0..4) |k| {
            const shift = 8 * k;
            var sum: u32 = 2;
            for (four) |texel| sum += texel >> shift & 0xFF;
            out |= (sum >> 2) << shift;
        }
        into[y * across + x] = out;
    };
}

const testing = std.testing;

test "a picture's texture: the nearest powers of two, as many levels as halving makes" {
    try testing.expectEqual(Shape{ .width = 256, .height = 64, .levels = 9 }, Shape.of(256, 64));
    try testing.expectEqual(Shape{ .width = 512, .height = 256, .levels = 10 }, Shape.of(400, 300));
    try testing.expectEqual(Shape{ .width = 256, .height = 1, .levels = 9 }, Shape.of(300, 1));
    try testing.expectEqual(Shape{ .width = most_side, .height = most_side, .levels = most_levels }, Shape.of(5000, 1600));
    try testing.expectEqual(@as(usize, (4 * 2 + 2 * 1 + 1 * 1) * 4), (Shape{ .width = 4, .height = 2, .levels = 3 }).bytes());
}

test "a picture of the right size copied as it is, its levels the means of four" {
    // Two by two: red, green over blue, white.
    const pixels = [4]u32{ 0xFFFF_0000, 0xFF00_FF00, 0xFF00_00FF, 0xFFFF_FFFF };
    const shape = Shape.of(2, 2);
    var staged: [5]u32 = undefined;
    stage(@ptrCast(&pixels), 2, 2, 8, shape, @ptrCast(&staged));
    try testing.expectEqualSlices(u32, &pixels, staged[0..4]);
    try testing.expectEqual(@as(u32, 0xFF80_8080), staged[4]);
    const made = regions(shape);
    try testing.expectEqual(@as(u64, 16), made[1].buffer_offset);
    try testing.expectEqual(@as(u32, 1), made[1].image_subresource.mip_level);
    try testing.expectEqual(@as(u32, 1), made[1].image_extent.width);
}

test "a picture scaled up: what lies between two pixels mixed from both, the edges held" {
    // Black and white side by side, made four wide.
    const pixels = [2]u32{ 0xFF00_0000, 0xFFFF_FFFF };
    const shape = Shape{ .width = 4, .height = 1, .levels = 1 };
    var staged: [4]u32 = undefined;
    stage(@ptrCast(&pixels), 2, 1, 8, shape, @ptrCast(&staged));
    try testing.expectEqual(@as(u32, 0xFF00_0000), staged[0]);
    try testing.expect(staged[1] & 0xFF > 0 and staged[1] & 0xFF < staged[2] & 0xFF);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), staged[3]);
}
