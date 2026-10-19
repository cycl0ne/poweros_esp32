// SPDX-License-Identifier: MPL-2.0
//! Host tests of triangles whose colour changes over them - smooth
//! colours and textures, mixed in perspective and drawn in quads - and of
//! colours laid over what is there by their alpha.

const std = @import("std");
const raster = @import("../raster.zig");
const common = @import("raster.zig");
const testing = std.testing;

const Target = raster.Target;
const Rect = raster.Rect;
const Texture = raster.Texture;
const width = common.width;
const height = common.height;

const whole = raster.Viewport{ .x = 0, .y = 0, .width = width, .height = height };
const all = Rect{ .x = 0, .y = 0, .width = width, .height = height };

/// Seen from the origin down z: (x, y, z) lands where (x / z, y / z) is
/// in clip space, with a w of z and a depth inside the view from z = 1 on.
const perspective: raster.Matrix = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0.5, 1, 0, 0, -0.5, 0 };

fn targetOn(pixels: []u32, log: *common.Log, threads: bool, attachments: raster.Attachments) !Target {
    return Target.init(common.host(log, threads), common.surfaceOf(pixels, .bgra32), all, attachments);
}

fn drawOnce(target: *Target, pipeline: anytype, vertices: anytype, indices: []const u16) !void {
    // Only the frame's rectangles handed on are kept.
    const log: *common.Log = @ptrCast(@alignCast(target.host.context.?));
    log.count = 0;
    target.begin();
    try raster.draw(target, pipeline, vertices, indices);
    _ = target.finish();
}

/// A point on the surface in pixels, not snapped, and its w.
const Point = struct { x: f64, y: f64, w: f64 };

fn pointOf(p: [3]f32, m: raster.Matrix) Point {
    var clip: [4]f64 = undefined;
    for (&clip, 0..) |*c, row| c.* = @as(f64, m[row]) * p[0] + @as(f64, m[4 + row]) * p[1] + @as(f64, m[8 + row]) * p[2] + m[12 + row];
    return .{
        .x = whole.x + (clip[0] / clip[3] + 1) * whole.width / 2,
        .y = whole.y + (clip[1] / clip[3] + 1) * whole.height / 2,
        .w = clip[3],
    };
}

const Mixed = enum { flat, seen };

/// The weights of a triangle's vertices at (x, y) on the surface: as the
/// surface has them, each the area of the triangle the point makes with
/// the other two; or as the eye sees them, each of those over its
/// vertex's w, all over their sum.
fn weights(t: [3]Point, x: f64, y: f64, mixed: Mixed) [3]f64 {
    const area = (t[1].x - t[0].x) * (t[2].y - t[0].y) - (t[1].y - t[0].y) * (t[2].x - t[0].x);
    var made: [3]f64 = undefined;
    for (&made, 0..) |*weight, i| {
        const a = t[(i + 1) % 3];
        const c = t[(i + 2) % 3];
        weight.* = ((c.x - a.x) * (y - a.y) - (c.y - a.y) * (x - a.x)) / area;
    }
    if (mixed == .flat) return made;
    var sum: f64 = 0;
    for (&made, t) |*weight, point| {
        weight.* /= point.w;
        sum += weight.*;
    }
    for (&made) |*weight| weight.* /= sum;
    return made;
}

/// A texel of its own for every (x, y).
fn texelAt(x: u32, y: u32) u32 {
    return 0xFF00_0000 | x << 16 | y << 8 | (x ^ y);
}

test "drawn in quads, a smooth triangle of one colour covers what a flat one does, depth and all" {
    const pixels = try testing.allocator.alloc(u32, width * height);
    defer testing.allocator.free(pixels);
    const flat_pixels = try testing.allocator.alloc(u32, width * height);
    defer testing.allocator.free(flat_pixels);
    var log: common.Log = .{};
    const attachments = raster.Attachments{ .color = .{ .clear = 0xFF00_0000 }, .depth = .{ .used = true } };
    var target = try targetOn(pixels, &log, false, attachments);
    defer target.deinit();
    var flat_target = try targetOn(flat_pixels, &log, false, attachments);
    defer flat_target.deinit();

    const Flat = raster.Pipeline(.{ .color = .flat, .cull = .none });
    const Smooth = raster.Pipeline(.{ .color = .smooth, .cull = .none });
    const FlatDeep = raster.Pipeline(.{ .color = .flat, .cull = .none, .depth = .less });
    const SmoothDeep = raster.Pipeline(.{ .color = .smooth, .cull = .none, .depth = .less });
    const SmoothLate = raster.Pipeline(.{ .color = .smooth, .cull = .none, .depth = .less, .early_depth = false });
    const indices = [_]u16{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

    var random = std.Random.DefaultPrng.init(0xC0FFEE);
    const r = random.random();
    for (0..300) |round| {
        // Four triangles of a colour each, sloping through each other in
        // depth: small, middling, large, and on a grid of pixels.
        var vertices: [12]Flat.Vertex = undefined;
        for (0..4) |t| {
            const reach: f32 = switch (round % 4) {
                0 => 0.05,
                1 => 0.4,
                2 => 1.6,
                else => 0,
            };
            const middle = [2]f32{ r.float(f32) * 2 - 1, r.float(f32) * 2 - 1 };
            const color = 0xFF00_0000 | @as(u32, r.int(u24));
            for (vertices[t * 3 ..][0..3]) |*vertex| vertex.* = .{ .position = if (reach != 0) .{
                middle[0] + (r.float(f32) * 2 - 1) * reach,
                middle[1] + (r.float(f32) * 2 - 1) * reach,
                r.float(f32),
            } else .{
                common.onGrid(r, width),
                common.onGrid(r, height),
                r.float(f32),
            }, .color = color };
        }
        inline for (.{ .{ Flat, Smooth }, .{ FlatDeep, SmoothDeep }, .{ FlatDeep, SmoothLate } }) |kinds| {
            var flat_vertices: [12]kinds[0].Vertex = undefined;
            for (&flat_vertices, vertices) |*into, vertex| into.* = .{ .position = vertex.position, .color = vertex.color };
            var smooth_vertices: [12]kinds[1].Vertex = undefined;
            for (&smooth_vertices, vertices) |*into, vertex| into.* = .{ .position = vertex.position, .color = vertex.color };
            try drawOnce(&flat_target, &kinds[0]{ .viewport = whole }, &flat_vertices, &indices);
            try drawOnce(&target, &kinds[1]{ .viewport = whole }, &smooth_vertices, &indices);
            for (flat_pixels, pixels, 0..) |want, got, at| if (want != got) {
                std.debug.print("{s}, round {d}, pixel {d},{d}: {x}, not {x}\n", .{ @typeName(kinds[1]), round, at % width, at / width, got, want });
                return error.TestExpectedEqual;
            };
        }
    }
}

test "a smooth triangle mixes its vertices' colours as the eye sees them" {
    const pixels = try testing.allocator.alloc(u32, width * height);
    defer testing.allocator.free(pixels);
    var log: common.Log = .{};
    var target = try targetOn(pixels, &log, false, .{ .color = .{ .clear = 0 } });
    defer target.deinit();
    const Smooth = raster.Pipeline(.{ .color = .smooth, .cull = .none });
    const pipeline = Smooth{ .viewport = whole, .transform = perspective };
    const colors = [3]u32{ 0xFFFF_0000, 0xFF00_FF00, 0xFF00_00FF };
    const screen = [3][2]f32{ .{ -0.9, -0.8 }, .{ 0.9, -0.5 }, .{ -0.2, 0.9 } };
    // The same on the surface: first all as near, then the second six
    // times as far as the first and the third three times.
    for ([_][3]f32{ .{ 1, 1, 1 }, .{ 1, 6, 3 } }) |depths| {
        var vertices: [3]Smooth.Vertex = undefined;
        var corners: [3]Point = undefined;
        for (&vertices, &corners, screen, depths, colors) |*vertex, *corner, s, z, color| {
            vertex.* = .{ .position = .{ s[0] * z, s[1] * z, z }, .color = color };
            corner.* = pointOf(vertex.position, perspective);
        }
        try drawOnce(&target, &pipeline, &vertices, &.{ 0, 1, 2 });
        var drawn: u32 = 0;
        // Channels the surface's own mix would have put more than 4 away.
        var apart: u32 = 0;
        for (0..height) |y| for (0..width) |x| {
            const got = pixels[y * width + x];
            if (got == 0) continue;
            drawn += 1;
            try testing.expectEqual(@as(u32, 0xFF), got >> 24);
            const at_x = @as(f64, @floatFromInt(x)) + 0.5;
            const at_y = @as(f64, @floatFromInt(y)) + 0.5;
            const seen = weights(corners, at_x, at_y, .seen);
            const flat = weights(corners, at_x, at_y, .flat);
            for ([_]u5{ 16, 8, 0 }) |shift| {
                var want: f64 = 0;
                var flat_want: f64 = 0;
                for (colors, seen, flat) |color, by_eye, by_surface| {
                    const value: f64 = @floatFromInt(color >> shift & 0xFF);
                    want += by_eye * value;
                    flat_want += by_surface * value;
                }
                const value: f64 = @floatFromInt(got >> shift & 0xFF);
                if (@abs(value - want) > 1) {
                    std.debug.print("pixel {d},{d}: {x}, channel at {d} should be {d}\n", .{ x, y, got, shift, want });
                    return error.TestExpectedEqual;
                }
                if (@abs(flat_want - want) > 4) apart += 1;
            }
        };
        try testing.expect(drawn > 10000);
        if (depths[1] == 1) try testing.expectEqual(@as(u32, 0), apart) else try testing.expect(apart > 5000);
    }
}

/// Whether `got` is the texel (s, t) - in texels - lies in, or where it is
/// within 1/50 of a texel of the next, that one.
fn isTexelNear(got: u32, s: f64, t: f64, side: u32) bool {
    for (texelsNear(s, side)) |x| for (texelsNear(t, side)) |y| {
        if (got == texelAt(x, y)) return true;
    };
    return false;
}

fn texelsNear(at: f64, side: u32) [2]u32 {
    const last: f64 = @floatFromInt(side - 1);
    return .{
        @intFromFloat(std.math.clamp(@floor(at - 0.02), 0, last)),
        @intFromFloat(std.math.clamp(@floor(at + 0.02), 0, last)),
    };
}

test "a quad in perspective is textured with no bend at its diagonal" {
    const pixels = try testing.allocator.alloc(u32, width * height);
    defer testing.allocator.free(pixels);
    var log: common.Log = .{};
    var target = try targetOn(pixels, &log, false, .{ .color = .{ .clear = 0 } });
    defer target.deinit();
    const side = 32;
    var memory: [side * side]u64 = undefined;
    var made = try Texture.init(.rgba8888, side, side, 1, @ptrCast(&memory));
    for (0..side) |y| for (0..side) |x| made.put(0, @intCast(x), @intCast(y), texelAt(@intCast(x), @intCast(y)));

    const Pictured = raster.Pipeline(.{ .color = .texture, .sampling = .{ .filter = .nearest, .address = .clamp }, .cull = .none });
    const pipeline = Pictured{ .viewport = whole, .transform = perspective, .texture = &made };
    // A rectangle sloping away from the eye, its near edge at a depth of
    // 1.25, its far one at 4, cut in two along the diagonal from 0 to 2.
    const vertices = [4]Pictured.Vertex{
        .{ .position = .{ -1, -1, 1.25 }, .uv = .{ 0, 0 } },
        .{ .position = .{ 1, -1, 1.25 }, .uv = .{ 1, 0 } },
        .{ .position = .{ 1, 2.4, 4 }, .uv = .{ 1, 1 } },
        .{ .position = .{ -1, 2.4, 4 }, .uv = .{ 0, 1 } },
    };
    try drawOnce(&target, &pipeline, &vertices, &.{ 0, 1, 2, 0, 2, 3 });
    var corners: [4]Point = undefined;
    for (&corners, vertices) |*corner, vertex| corner.* = pointOf(vertex.position, perspective);
    const first = [3]Point{ corners[0], corners[1], corners[2] };
    const second = [3]Point{ corners[0], corners[2], corners[3] };

    var drawn: u32 = 0;
    // Pixels that would have another texel, mixed flat over each half.
    var bent: u32 = 0;
    for (0..height) |y| for (0..width) |x| {
        const got = pixels[y * width + x];
        if (got == 0) continue;
        drawn += 1;
        const at_x = @as(f64, @floatFromInt(x)) + 0.5;
        const at_y = @as(f64, @floatFromInt(y)) + 0.5;
        // The quad is flat: as the eye sees it, the weights of the first
        // half hold over the second as well.
        const seen = weights(first, at_x, at_y, .seen);
        const s = (seen[1] + seen[2]) * side;
        const t = seen[2] * side;
        if (!isTexelNear(got, s, t, side)) {
            std.debug.print("pixel {d},{d}: {x}, not the texel at {d},{d}\n", .{ x, y, got, s, t });
            return error.TestExpectedEqual;
        }
        const in_first = for (weights(first, at_x, at_y, .flat)) |weight| {
            if (weight < 0) break false;
        } else true;
        const flat = weights(if (in_first) first else second, at_x, at_y, .flat);
        const flat_s = if (in_first) (flat[1] + flat[2]) * side else flat[1] * side;
        const flat_t = if (in_first) flat[2] * side else (flat[1] + flat[2]) * side;
        if (!isTexelNear(texelAt(texelsNear(s, side)[0], texelsNear(t, side)[0]), flat_s, flat_t, side)) bent += 1;
    };
    try testing.expect(drawn > 10000);
    try testing.expect(bent > 1000);
}

test "a texture's level follows how many of its texels a pixel steps over" {
    const pixels = try testing.allocator.alloc(u32, width * height);
    defer testing.allocator.free(pixels);
    var log: common.Log = .{};
    var target = try targetOn(pixels, &log, false, .{ .color = .{ .clear = 0 } });
    defer target.deinit();
    // 16 x 16, 8 x 8, 4 x 4, and 2 x 2 in a block of its own.
    var memory: [256 + 64 + 16 + 16]u16 = undefined;
    var made = try Texture.init(.rgb565, 16, 16, 4, @ptrCast(&memory));
    const shades = [4]u16{ 0x001F, 0x07E0, 0xF800, 0xFFFF };
    for (shades, 0..) |shade, lod| {
        for (0..made.height(@intCast(lod))) |y| for (0..made.width(@intCast(lod))) |x| made.put(@intCast(lod), @intCast(x), @intCast(y), shade);
    }
    const Leveled = raster.Pipeline(.{ .color = .texture, .sampling = .{ .format = .rgb565, .filter = .bilinear }, .cull = .none });
    const pipeline = Leveled{ .viewport = whole, .texture = &made };
    for ([_]u32{ 16, 8, 4, 2 }, shades) |size, shade| {
        // A square of size x size pixels, the texture over it once.
        const left: f32 = 20;
        const top: f32 = 30;
        const right = left + @as(f32, @floatFromInt(size));
        const bottom = top + @as(f32, @floatFromInt(size));
        const vertices = [4]Leveled.Vertex{
            .{ .position = .{ left * 2 / width - 1, top * 2 / height - 1, 0.5 }, .uv = .{ 0, 0 } },
            .{ .position = .{ right * 2 / width - 1, top * 2 / height - 1, 0.5 }, .uv = .{ 1, 0 } },
            .{ .position = .{ right * 2 / width - 1, bottom * 2 / height - 1, 0.5 }, .uv = .{ 1, 1 } },
            .{ .position = .{ left * 2 / width - 1, bottom * 2 / height - 1, 0.5 }, .uv = .{ 0, 1 } },
        };
        try drawOnce(&target, &pipeline, &vertices, &.{ 0, 1, 2, 0, 2, 3 });
        const want = @import("../texture.zig").widen(shade);
        var drawn: u32 = 0;
        for (pixels) |pixel| {
            if (pixel == 0) continue;
            try testing.expectEqual(want, pixel);
            drawn += 1;
        }
        try testing.expectEqual(size * size, drawn);
    }
}

test "a colour laid over what is there by its alpha, flat or smooth" {
    const pixels = try testing.allocator.alloc(u32, width * height);
    defer testing.allocator.free(pixels);
    var log: common.Log = .{};
    var target = try targetOn(pixels, &log, false, .{ .color = .{ .clear = 0xFF00_0000 } });
    defer target.deinit();
    const Over = raster.Pipeline(.{ .color = .flat, .cull = .none, .blend = .alpha });
    const SmoothOver = raster.Pipeline(.{ .color = .smooth, .cull = .none, .blend = .alpha });
    inline for (.{ Over, SmoothOver }) |Kind| {
        const half_red = 0x80FF_0000;
        const vertices = [3]Kind.Vertex{
            .{ .position = .{ -0.8, -0.8, 0.5 }, .color = half_red },
            .{ .position = .{ 0.8, -0.6, 0.5 }, .color = half_red },
            .{ .position = .{ 0.1, 0.8, 0.5 }, .color = half_red },
        };
        const pipeline = Kind{ .viewport = whole };
        // Once over black, then twice.
        for ([_][]const u16{ &.{ 0, 1, 2 }, &.{ 0, 1, 2, 0, 1, 2 } }, [_]u32{ 0xBF80_0000, 0x9FBF_0000 }) |indices, want| {
            try drawOnce(&target, &pipeline, &vertices, indices);
            var drawn: u32 = 0;
            for (pixels) |pixel| {
                if (pixel == 0xFF00_0000) continue;
                try testing.expectEqual(want, pixel);
                drawn += 1;
            }
            try testing.expect(drawn > 10000);
        }
    }
}

test "a texture missing, or in another format, is refused" {
    var pixels: [width * height]u32 = undefined;
    var log: common.Log = .{};
    var target = try targetOn(&pixels, &log, false, .{});
    defer target.deinit();
    var memory: [16]u16 = undefined;
    const made = try Texture.init(.rgb565, 4, 4, 1, @ptrCast(&memory));
    const Pictured = raster.Pipeline(.{ .color = .texture });
    const vertices = [3]Pictured.Vertex{ .{ .position = .{ 0, 0, 0.5 } }, .{ .position = .{ 1, 0, 0.5 } }, .{ .position = .{ 0, 1, 0.5 } } };
    target.begin();
    try testing.expectError(error.BadTexture, raster.draw(&target, &Pictured{ .viewport = whole }, &vertices, &[_]u16{ 0, 1, 2 }));
    try testing.expectError(error.BadTexture, raster.draw(&target, &Pictured{ .viewport = whole, .texture = &made }, &vertices, &[_]u16{ 0, 1, 2 }));
    _ = target.finish();
}

test "with a texture, early and late depth, on one part or on threads, draw the same frame" {
    const Early = raster.Pipeline(.{ .color = .texture, .cull = .none, .depth = .less });
    const Late = raster.Pipeline(.{ .color = .texture, .cull = .none, .depth = .less, .early_depth = false });
    const side = 64;
    const memory = try testing.allocator.alloc(u64, try Texture.bytes(.rgba8888, side, side, 4) / 8);
    defer testing.allocator.free(memory);
    var made = try Texture.init(.rgba8888, side, side, 4, @ptrCast(memory.ptr));
    for (0..4) |lod| {
        const level: u32 = @intCast(lod);
        for (0..made.height(level)) |y| for (0..made.width(level)) |x| {
            made.put(level, @intCast(x), @intCast(y), texelAt(@intCast(x * 4), @intCast(y * 4)) ^ level * 0x40);
        };
    }
    // Two rectangles sloping through each other, the texture three times
    // over each, wrapped.
    const vertices = [8]Early.Vertex{
        .{ .position = .{ -1.5, -1, 1.5 }, .uv = .{ 0, 0 } },
        .{ .position = .{ 1.5, -1, 1.5 }, .uv = .{ 3, 0 } },
        .{ .position = .{ 1.5, 2, 5 }, .uv = .{ 3, 3 } },
        .{ .position = .{ -1.5, 2, 5 }, .uv = .{ 0, 3 } },
        .{ .position = .{ -2, 1, 1.5 }, .uv = .{ 0, 0 } },
        .{ .position = .{ 2, 1, 1.5 }, .uv = .{ 3, 0 } },
        .{ .position = .{ 2, -2, 6 }, .uv = .{ 3, 3 } },
        .{ .position = .{ -2, -2, 6 }, .uv = .{ 0, 3 } },
    };
    const indices = [_]u16{ 0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7 };
    const first = try testing.allocator.alloc(u32, width * height);
    defer testing.allocator.free(first);
    const pixels = try testing.allocator.alloc(u32, width * height);
    defer testing.allocator.free(pixels);
    var log: common.Log = .{};
    const attachments = raster.Attachments{ .color = .{ .clear = 0 }, .depth = .{ .used = true } };
    inline for (.{ Early, Late }, 0..) |Kind, k| {
        var late_vertices: [8]Kind.Vertex = undefined;
        for (&late_vertices, vertices) |*into, vertex| into.* = .{ .position = vertex.position, .uv = vertex.uv };
        for ([_]bool{ false, true }) |threads| {
            const into = if (k == 0 and !threads) first else pixels;
            var target = try targetOn(into, &log, threads, attachments);
            defer target.deinit();
            try drawOnce(&target, &Kind{ .viewport = whole, .transform = perspective, .texture = &made }, &late_vertices, &indices);
            try testing.expectEqualSlices(u32, first, into);
        }
    }
    var drawn: u32 = 0;
    for (first) |pixel| drawn += @intFromBool(pixel != 0);
    try testing.expect(drawn > 20000);
}
