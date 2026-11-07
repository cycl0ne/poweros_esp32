// SPDX-License-Identifier: MPL-2.0
//! Which of a pixel's samples are inside a triangle, at four samples a
//! pixel and at one: setup's box, the tiles a triangle is binned into and
//! the runs the walk hands on, each held to the sample tested on its own
//! against the triangle's vertices. (Since 1.102.)

const std = @import("std");
const raster = @import("../raster.zig");
const setup = @import("../setup.zig");
const bins = @import("../bins.zig");
const walk = @import("../walk.zig");
const Tile = @import("../target.zig").Tile;
const common = @import("raster.zig");
const testing = std.testing;

const Rect = raster.Rect;
const Projected = setup.Projected;
const tile_size = raster.tile_size;
const width = common.width;
const height = common.height;

/// Vulkan's standard positions of a pixel's samples, x and y in 1/256ths
/// of a pixel from its top left: the four of the spec's table, which
/// lavapipe has as `lp_sample_pos_4x` and says it keeps
/// (`standardSampleLocations`, lvp_device.c:1094), and the one of one
/// sample a pixel, the centre. Written down again here rather than taken
/// from setup.
fn positionsOf(comptime samples: u32) [samples][2]i64 {
    return switch (samples) {
        1 => .{.{ 128, 128 }},
        4 => .{ .{ 96, 32 }, .{ 224, 96 }, .{ 32, 160 }, .{ 160, 224 } },
        else => unreachable,
    };
}

/// Whether the point (x, y), in 1/256ths of a pixel, is inside the
/// triangle `v`: inside all three of its edges, or on one that is a top
/// or a left edge - its vertices taken clockwise on a surface whose y runs
/// down, a top edge runs right and a left one up.
fn holds(v: [3]Projected, x: i64, y: i64) bool {
    var p = v;
    const twice = (p[1].x - p[0].x) * (p[2].y - p[0].y) - (p[1].y - p[0].y) * (p[2].x - p[0].x);
    if (twice == 0) return false;
    if (twice < 0) std.mem.swap(Projected, &p[1], &p[2]);
    for (0..3) |i| {
        const from = p[(i + 1) % 3];
        const to = p[(i + 2) % 3];
        const dx = to.x - from.x;
        const dy = to.y - from.y;
        const cross = dx * (y - from.y) - dy * (x - from.x);
        const top_left = (dy == 0 and dx > 0) or dy < 0;
        if (cross < 0 or (cross == 0 and !top_left)) return false;
    }
    return true;
}

/// What the walk hands on, put down a pixel at a time - bit s of a
/// pixel's byte its sample s - and how many samples it handed on twice or
/// off the surface.
fn Seen(comptime samples: u32) type {
    return struct {
        tile: *const Tile,
        bits: []u8,
        wrong: *u32,

        const Self = @This();

        fn run(seen: Self, y: u32, upper: anytype, lower: anytype) void {
            var x: u32 = 0;
            while (x < tile_size) : (x += 2) {
                const mask: u16 = if (samples == 1)
                    @as(u16, @intFromBool(upper.holds(x))) | @as(u16, @intFromBool(upper.holds(x + 1))) << 1 |
                        @as(u16, @intFromBool(lower.holds(x))) << 2 | @as(u16, @intFromBool(lower.holds(x + 1))) << 3
                else
                    walk.sampleMask(upper, lower, x);
                for (0..4) |i| for (0..samples) |s| {
                    if ((mask >> @intCast(4 * s + i)) & 1 == 0) continue;
                    const px = seen.tile.x + x + @as(u32, @intCast(i % 2));
                    const py = seen.tile.y + y + @as(u32, @intCast(i / 2));
                    const bit = @as(u8, 1) << @intCast(s);
                    if (px >= width or py >= height or seen.bits[py * width + px] & bit != 0) {
                        seen.wrong.* += 1;
                        continue;
                    }
                    seen.bits[py * width + px] |= bit;
                };
            }
        }
    };
}

/// The samples of `v` inside it at `samples` a pixel as the cores take
/// them - set up, binned and walked tile by tile, into `bits` - held to
/// each sample's own test: every one inside handed on once and no other,
/// so none of them outside the box, and every tile with one binned.
fn expectSamples(comptime samples: u32, target: *raster.Target, v: [3]Projected, bits: []u8) !void {
    @memset(bits, 0);
    var wrong: u32 = 0;
    const area = target.area;
    var binned: [64]bool = @splat(false);
    if (setup.onSurface(v, .none, .clockwise, target.areaBounds(), samples)) |made| {
        var header = bins.Header{ .raster = undefined, .left = made.left, .top = made.top, .right = made.right, .bottom = made.bottom, .edges = made.edges };
        bins.sortForWalk(&header.edges);
        target.begin();
        try target.addPending(&header);
        try target.bin(0);
        for (target.tiles, 0..) |state, index| {
            binned[index] = state.list.first != null;
            const x = target.grid_x + @as(u32, @intCast(index)) % target.columns * tile_size;
            const y = target.grid_y + @as(u32, @intCast(index)) / target.columns * tile_size;
            const tile = Tile{
                .buffer = undefined,
                .index = @intCast(index),
                .x = x,
                .y = y,
                .left = @max(x, area.x) - x,
                .top = @max(y, area.y) - y,
                .right = @min(x + tile_size, area.x + area.width) - x,
                .bottom = @min(y + tile_size, area.y + area.height) - y,
            };
            walk.quads(samples, &tile, &header, Seen(samples){ .tile = &tile, .bits = bits, .wrong = &wrong }, Seen(samples).run);
        }
    }
    try testing.expectEqual(@as(u32, 0), wrong);
    // Only the pixels about the triangle are asked; the others have none.
    const lo_x = @divFloor(@min(v[0].x, v[1].x, v[2].x), 256) - 1;
    const hi_x = @divFloor(@max(v[0].x, v[1].x, v[2].x), 256) + 1;
    const lo_y = @divFloor(@min(v[0].y, v[1].y, v[2].y), 256) - 1;
    const hi_y = @divFloor(@max(v[0].y, v[1].y, v[2].y), 256) + 1;
    for (0..height) |py| for (0..width) |px| {
        const x: i64 = @intCast(px);
        const y: i64 = @intCast(py);
        var want: u8 = 0;
        if (x >= lo_x and x <= hi_x and y >= lo_y and y <= hi_y and common.inside(area, @intCast(px), @intCast(py))) {
            for (positionsOf(samples), 0..) |position, s| {
                if (holds(v, x * 256 + position[0], y * 256 + position[1])) want |= @as(u8, 1) << @intCast(s);
            }
        }
        const got = bits[py * width + px];
        if (want != got) {
            std.debug.print("{d} samples a pixel, pixel {d},{d}: samples {b:0>4} handed on, not {b:0>4}\n", .{ samples, px, py, got, want });
            return error.TestExpectedEqual;
        }
        if (want != 0) {
            const index = (@as(u32, @intCast(py)) - target.grid_y) / tile_size * target.columns + (@as(u32, @intCast(px)) - target.grid_x) / tile_size;
            if (!binned[index]) {
                std.debug.print("{d} samples a pixel, pixel {d},{d}: its tile not binned\n", .{ samples, px, py });
                return error.TestExpectedEqual;
            }
        }
    };
}

fn vertex(x: i64, y: i64) Projected {
    return .{ .x = x, .y = y, .z = 0.5, .inverse_w = 1 };
}

/// Somewhere from 8 pixels before `from` to 8 past `from + length`, in
/// 1/256ths of a pixel: anywhere in its pixel, or on the samples' grid -
/// 32 times 0 to 7, the samples' columns and rows and the pixel's corner
/// and centre between them.
fn point(r: std.Random, from: u32, length: u32, grid: bool) i64 {
    const pixel = @as(i64, from) - 8 + r.intRangeLessThan(i64, 0, @as(i64, length) + 16);
    return pixel * 256 + if (grid) 32 * r.intRangeLessThan(i64, 0, 8) else r.intRangeLessThan(i64, 0, 256);
}

/// A triangle about the area, of one of seven shapes: anywhere; small;
/// small on the samples' grid; a sliver, two vertices a fifth of a pixel
/// apart; anywhere on the grid; and on the grid with an edge along the
/// rows, or along the columns.
fn shapeOf(r: std.Random, shape: usize, area: Rect) [3]Projected {
    const grid = shape == 2 or shape >= 4;
    const cx = point(r, area.x, area.width, grid);
    const cy = point(r, area.y, area.height, grid);
    var v: [3]Projected = undefined;
    for (&v) |*at| at.* = switch (shape) {
        0, 3, 4 => vertex(point(r, area.x, area.width, grid), point(r, area.y, area.height, grid)),
        1 => vertex(cx + r.intRangeAtMost(i64, -768, 768), cy + r.intRangeAtMost(i64, -768, 768)),
        else => vertex(cx + 32 * r.intRangeAtMost(i64, -96, 96), cy + 32 * r.intRangeAtMost(i64, -96, 96)),
    };
    switch (shape) {
        3 => v[1] = vertex(v[0].x + r.intRangeAtMost(i64, -48, 48), v[0].y + r.intRangeAtMost(i64, -48, 48)),
        5 => v[1].y = v[0].y,
        6 => v[1].x = v[0].x,
        else => {},
    }
    return v;
}

test "a quad's samples, bit 4s + i sample s of its pixel i, and the pixels with any of them" {
    const none = walk.Span.none;
    // Sample 0 of the upper left pixel, 1 of the upper right, 2 of the
    // lower left and 3 of both lower ones.
    const upper = [4]walk.Span{ .{ .left = 10, .right = 11 }, .{ .left = 11, .right = 12 }, none, none };
    const lower = [4]walk.Span{ none, none, .{ .left = 9, .right = 11 }, .{ .left = 10, .right = 30 } };
    const mask = walk.sampleMask(upper, lower, 10);
    try testing.expectEqual(@as(u16, 1 << 0 | 1 << 5 | 1 << 10 | 1 << 14 | 1 << 15), mask);
    // The quads to either side: (11, 12) has sample 1 of its upper left
    // and 3 of both lower pixels, (9, 10) sample 0 of its upper right, 2
    // of both lower ones and 3 of its lower right.
    try testing.expectEqual(@as(u16, 1 << 4 | 1 << 14 | 1 << 15), walk.sampleMask(upper, lower, 11));
    try testing.expectEqual(@as(u16, 1 << 1 | 1 << 10 | 1 << 11 | 1 << 15), walk.sampleMask(upper, lower, 9));
    try testing.expectEqual(@as(u4, 0b1111), walk.pixelsOf(mask));
    try testing.expectEqual(@as(u4, 0b0001), walk.pixelsOf(1 << 12));
    try testing.expectEqual(@as(u4, 0b0100), walk.pixelsOf(1 << 10));
    try testing.expectEqual(@as(u4, 0b1000), walk.pixelsOf(1 << 7));
    try testing.expectEqual(@as(u4, 0), walk.pixelsOf(0));
}

test "every sample inside a triangle handed on once, and no other, at four samples a pixel and at one" {
    var pixels: [width * height]u32 = undefined;
    var bits: [width * height]u8 = undefined;
    var log: common.Log = .{};
    var target = try raster.Target.init(common.host(&log, false), common.surfaceOf(&pixels, .bgra32), .{ .x = 3, .y = 2, .width = 150, .height = 110 }, .{ .color = .{ .load = .keep } });
    defer target.deinit();
    var random = std.Random.DefaultPrng.init(0x5A3B1E);
    const r = random.random();
    for (0..700) |round| {
        const v = shapeOf(r, round % 7, target.area);
        errdefer std.debug.print("round {d}: {d},{d} {d},{d} {d},{d}\n", .{ round, v[0].x, v[0].y, v[1].x, v[1].y, v[2].x, v[2].y });
        try expectSamples(4, &target, v, &bits);
        try expectSamples(1, &target, v, &bits);
    }
}

test "two triangles on an edge through samples - down a column of them, along a row, across them - have each sample of it once" {
    var pixels: [width * height]u32 = undefined;
    var bits: [width * height]u8 = undefined;
    var first: [width * height]u8 = undefined;
    var log: common.Log = .{};
    var target = try raster.Target.init(common.host(&log, false), common.surfaceOf(&pixels, .bgra32), .{ .x = 0, .y = 0, .width = 192, .height = 128 }, .{ .color = .{ .load = .keep } });
    defer target.deinit();
    // The edge from p to q, with a vertex on either side: down x = 40.375
    // through sample 0, along y = 30.625 through sample 2, and through
    // sample 0 at slopes of 1/2 (and 1 on), -2 (and 2 on), 1 and -1.
    const p = 256 * 10 + 96;
    const cases = [_][4][2]i64{
        .{ .{ 256 * 40 + 96, 256 * 10 + 32 }, .{ 256 * 40 + 96, 256 * 50 + 224 }, .{ 256 * 20, 256 * 30 }, .{ 256 * 70 + 13, 256 * 31 + 7 } },
        .{ .{ 256 * 12 + 32, 256 * 30 + 160 }, .{ 256 * 60 + 224, 256 * 30 + 160 }, .{ 256 * 35, 256 * 5 }, .{ 256 * 33 + 77, 256 * 58 + 3 } },
        .{ .{ p, 256 * 10 + 32 }, .{ p + 256 * 32, 256 * 26 + 32 }, .{ p - 256 * 5, 256 * 22 }, .{ p + 256 * 35, 256 * 4 } },
        .{ .{ 256 * 60 + 96, 256 * 8 + 32 }, .{ 256 * 40 + 96, 256 * 48 + 32 }, .{ 256 * 35, 256 * 13 }, .{ 256 * 70, 256 * 38 } },
        .{ .{ p, 256 * 10 + 32 }, .{ p + 256 * 40, 256 * 50 + 32 }, .{ p - 256 * 2, 256 * 45 }, .{ p + 256 * 45, 256 * 12 } },
        .{ .{ p, 256 * 50 + 32 }, .{ p + 256 * 40, 256 * 10 + 32 }, .{ p + 256 * 3, 256 * 9 }, .{ p + 256 * 42, 256 * 55 } },
    };
    const positions = positionsOf(4);
    for (cases, 0..) |case, number| {
        errdefer std.debug.print("case {d}\n", .{number});
        const at = [4]Projected{ vertex(case[0][0], case[0][1]), vertex(case[1][0], case[1][1]), vertex(case[2][0], case[2][1]), vertex(case[3][0], case[3][1]) };
        try expectSamples(4, &target, .{ at[0], at[1], at[2] }, &first);
        try expectSamples(1, &target, .{ at[0], at[1], at[2] }, &bits);
        try expectSamples(1, &target, .{ at[1], at[0], at[3] }, &bits);
        try expectSamples(4, &target, .{ at[1], at[0], at[3] }, &bits);
        var on_edge: u32 = 0;
        for (0..height) |py| for (0..width) |px| {
            const both = first[py * width + px] & bits[py * width + px];
            if (both != 0) {
                std.debug.print("pixel {d},{d}: samples {b:0>4} in both\n", .{ px, py, both });
                return error.TestExpectedEqual;
            }
            // A sample on the edge between its ends is one of the two's.
            for (positions, 0..) |position, s| {
                const x = @as(i64, @intCast(px)) * 256 + position[0];
                const y = @as(i64, @intCast(py)) * 256 + position[1];
                const dx = case[1][0] - case[0][0];
                const dy = case[1][1] - case[0][1];
                const along = dx * (x - case[0][0]) + dy * (y - case[0][1]);
                if (dx * (y - case[0][1]) - dy * (x - case[0][0]) != 0 or along <= 0 or along >= dx * dx + dy * dy) continue;
                on_edge += 1;
                if ((first[py * width + px] | bits[py * width + px]) >> @intCast(s) & 1 == 0) {
                    std.debug.print("pixel {d},{d}: sample {d}, on the edge, in neither\n", .{ px, py, s });
                    return error.TestExpectedEqual;
                }
            }
        };
        try testing.expect(on_edge >= 20);
    }
}

test "a sliver with one sample in a tile, in the tile's corner pixel, is binned into that tile" {
    var pixels: [width * height]u32 = undefined;
    var bits: [width * height]u8 = undefined;
    var log: common.Log = .{};
    var target = try raster.Target.init(common.host(&log, false), common.surfaceOf(&pixels, .bgra32), .{ .x = 0, .y = 0, .width = 192, .height = 128 }, .{ .color = .{ .load = .keep } });
    defer target.deinit();
    // Its right edge down x = 64.1875, past the column of the left samples
    // (sample 2's, at 64.125) of the pixels at x = 64 and short of their
    // centres; its lowest point at y = 64.75, past sample 2 of the
    // pixel at (64, 64) - the top left of the tile at (64, 64) - and short
    // of the pixel under it.
    const v = [3]Projected{ vertex(256 * 32, 256 * 40), vertex(256 * 64 + 48, 256 * 64 + 192), vertex(256 * 64 + 48, 256 * 60) };
    try expectSamples(4, &target, v, &bits);
    try testing.expectEqual(@as(u8, 0b0100), bits[64 * width + 64]);
    for (64..128) |py| for (64..128) |px| {
        if (px != 64 or py != 64) try testing.expectEqual(@as(u8, 0), bits[py * width + px]);
    };
    try testing.expect(target.tiles[1 * target.columns + 1].list.first != null);
    // At one sample a pixel no centre of that tile is inside, and it is
    // not binned.
    try expectSamples(1, &target, v, &bits);
    try testing.expect(target.tiles[1 * target.columns + 1].list.first == null);
}
