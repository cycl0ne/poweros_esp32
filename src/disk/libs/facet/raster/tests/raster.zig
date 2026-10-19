// SPDX-License-Identifier: MPL-2.0
//! Host tests of the rasterizer core: frames drawn into plain memory, the
//! parts one after another or on threads of their own.

const std = @import("std");
const raster = @import("../raster.zig");
const setup = @import("../setup.zig");
const testing = std.testing;

const Target = raster.Target;
const Rect = raster.Rect;

/// What the host was asked: the rectangles handed on.
pub const Log = struct {
    handed: [1024]Rect = undefined,
    count: u32 = 0,
};

fn handOn(context: ?*anyopaque, area: Rect) void {
    const log: *Log = @ptrCast(@alignCast(context.?));
    log.handed[@atomicRmw(u32, &log.count, .Add, 1, .monotonic)] = area;
}

fn allocate(_: ?*anyopaque, bytes: usize) ?[*]u8 {
    const memory = testing.allocator.alloc(u8, bytes) catch return null;
    return memory.ptr;
}

fn free(_: ?*anyopaque, memory: [*]u8, bytes: usize) void {
    testing.allocator.free(memory[0..bytes]);
}

/// The parts on threads of their own, part 0 on the caller's.
fn onThreads(_: ?*anyopaque, work: raster.Work, data: ?*anyopaque, parts: u32) u32 {
    var threads: [raster.most_parts]std.Thread = undefined;
    var started: u32 = 1;
    while (started < parts) : (started += 1) {
        threads[started] = std.Thread.spawn(.{}, callPart, .{ work, data, started, parts }) catch break;
    }
    work(data, 0, started);
    for (threads[1..started]) |thread| thread.join();
    return started;
}

fn callPart(work: raster.Work, data: ?*anyopaque, part: u32, parts: u32) void {
    work(data, part, parts);
}

pub fn host(log: *Log, threads: bool) raster.Host {
    return .{
        .context = log,
        .share = if (threads) &onThreads else &raster.Host.oneAfterAnother,
        .hand_on = &handOn,
        .allocate = &allocate,
        .free = &free,
    };
}

pub const width = 300;
pub const height = 200;
pub const background: u32 = 0x1234_5678;

pub fn surfaceOf(pixels: []u32, format: raster.Format) raster.Surface {
    return .{ .pixels = @ptrCast(pixels.ptr), .pitch = width * 4, .width = width, .height = height, .format = format };
}

pub fn inside(area: Rect, x: u32, y: u32) bool {
    return x >= area.x and x < area.x + area.width and y >= area.y and y < area.y + area.height;
}

/// Every pixel of the area `color`, every other the background.
fn expectFilled(pixels: []const u32, area: Rect, color: u32) !void {
    for (0..height) |y| for (0..width) |x| {
        const want = if (inside(area, @intCast(x), @intCast(y))) color else background;
        if (pixels[y * width + x] != want) {
            std.debug.print("pixel {d},{d} is {x}, not {x}\n", .{ x, y, pixels[y * width + x], want });
            return error.TestExpectedEqual;
        }
    };
}

/// The rectangles handed on cover the area once, and nothing else.
fn expectHandedOn(log: *const Log, area: Rect) !void {
    var covered: [width * height]u8 = @splat(0);
    for (log.handed[0..log.count]) |rect| {
        for (rect.y..rect.y + rect.height) |y| for (rect.x..rect.x + rect.width) |x| {
            covered[y * width + x] += 1;
        };
    }
    for (0..height) |y| for (0..width) |x| {
        const want: u8 = if (inside(area, @intCast(x), @intCast(y))) 1 else 0;
        try testing.expectEqual(want, covered[y * width + x]);
    };
}

test "a frame cleared fills the area alone, a tile at a time" {
    var pixels: [width * height]u32 = @splat(background);
    var log: Log = .{};
    // Off a cache line on the left, and not whole tiles either way.
    const area = Rect{ .x = 13, .y = 7, .width = 150, .height = 100 };
    var target = try Target.init(host(&log, false), surfaceOf(&pixels, .bgra32), area, .{ .color = .{ .clear = 0xFF30_60C0 } });
    defer target.deinit();
    // The grid starts on the cache line the area starts in.
    try testing.expectEqual(@as(u32, 0), target.grid_x);
    try testing.expectEqual(@as(u32, 3), target.columns);
    try testing.expectEqual(@as(u32, 2), target.rows);

    target.begin();
    const done = target.finish();
    try testing.expectEqual(@as(u32, 6), done.tiles);
    try expectFilled(&pixels, area, 0xFF30_60C0);
    try expectHandedOn(&log, area);
}

test "a frame kept from the last writes nothing" {
    var pixels: [width * height]u32 = @splat(background);
    var log: Log = .{};
    const area = Rect{ .x = 64, .y = 0, .width = 200, .height = 200 };
    var target = try Target.init(host(&log, false), surfaceOf(&pixels, .bgra32), area, .{ .color = .{ .load = .keep } });
    defer target.deinit();
    target.begin();
    const done = target.finish();
    try testing.expectEqual(@as(u32, 0), done.tiles);
    try testing.expectEqual(@as(u32, 0), log.count);
    try expectFilled(&pixels, .{}, 0);
}

test "a colour in red, green, blue order" {
    var pixels: [width * height]u32 = @splat(background);
    var log: Log = .{};
    const area = Rect{ .x = 0, .y = 0, .width = width, .height = height };
    var target = try Target.init(host(&log, false), surfaceOf(&pixels, .rgba32), area, .{ .color = .{ .clear = 0x8011_2233 } });
    defer target.deinit();
    target.begin();
    _ = target.finish();
    try expectFilled(&pixels, area, 0x8033_2211);
}

test "the tiles shared between parts on threads of their own" {
    var pixels: [width * height]u32 = @splat(background);
    var log: Log = .{};
    const area = Rect{ .x = 37, .y = 11, .width = 251, .height = 177 };
    var target = try Target.init(host(&log, true), surfaceOf(&pixels, .bgra32), area, .{ .color = .{ .clear = 0xFFAB_CDEF } });
    defer target.deinit();
    var frame: u32 = 0;
    while (frame < 20) : (frame += 1) {
        log.count = 0;
        target.attachments.color.clear = 0xFF00_0000 | frame;
        target.begin();
        const done = target.finish();
        try testing.expectEqual(target.columns * target.rows, done.tiles);
        try testing.expectEqual(@as(u32, raster.most_parts), done.parts);
        try expectFilled(&pixels, area, 0xFF00_0000 | frame);
        try expectHandedOn(&log, area);
    }
}

test "an area not inside the surface is refused" {
    var pixels: [width * height]u32 = @splat(background);
    var log: Log = .{};
    const surface = surfaceOf(&pixels, .bgra32);
    try testing.expectError(error.OutOfBounds, Target.init(host(&log, false), surface, .{ .x = 290, .y = 0, .width = 20, .height = 10 }, .{}));
    try testing.expectError(error.OutOfBounds, Target.init(host(&log, false), surface, .{ .x = 0, .y = 0, .width = 0, .height = 10 }, .{}));
}

// --- triangles ---------------------------------------------------------------

/// A small surface, for triangles counted pixel by pixel.
const Small = struct {
    const side = 16;
    pixels: [side * side]u32 = @splat(background),
    log: Log = .{},

    fn target(small: *Small, attachments: raster.Attachments) !Target {
        const surface = raster.Surface{ .pixels = @ptrCast(&small.pixels), .pitch = side * 4, .width = side, .height = side, .format = .bgra32 };
        return Target.init(host(&small.log, false), surface, .{ .width = side, .height = side }, attachments);
    }

    /// Which pixels are `color`, a row of '#' and '.' each.
    fn expectShape(small: *const Small, color: u32, comptime rows: []const []const u8) !void {
        for (rows, 0..) |row, y| for (row, 0..) |char, x| {
            const want = char == '#';
            const got = small.pixels[y * side + x] == color;
            if (want != got) {
                std.debug.print("pixel {d},{d}: {s}\n", .{ x, y, if (got) "drawn" else "not drawn" });
                return error.TestExpectedEqual;
            }
        };
    }
};

/// A point given in pixels on a 16 x 16 surface, as clip space with the
/// viewport over all of it.
fn at(x: f32, y: f32) [3]f32 {
    return .{ x * 2 / Small.side - 1, y * 2 / Small.side - 1, 0.5 };
}

const whole_small = raster.Viewport{ .x = 0, .y = 0, .width = Small.side, .height = Small.side };

const Flat = raster.Pipeline(.{ .color = .flat, .front = .clockwise });

// Worked out by hand: the triangle (1.5, 1.5), (7.5, 1.5), (1.5, 7.5) has
// a top edge on the centres of row 1 and a left edge on those of column
// 1, both its own; its long edge runs through the centres where
// x + y = 9, which belong to the triangle on its other side. So it holds
// the pixels with column >= 1, row >= 1 and column + row <= 7.
const upper_left = [_][]const u8{
    "................",
    ".######.........",
    ".#####..........",
    ".####...........",
    ".###............",
    ".##.............",
    ".#..............",
    "................",
    "................",
};
// The triangle on the other side of the long edge, to (7.5, 7.5): its
// right and bottom edges are not its own, so with the first it covers
// columns and rows 1 to 6 - each pixel once.
const lower_right = [_][]const u8{
    "................",
    "................",
    "......#.........",
    ".....##.........",
    "....###.........",
    "...####.........",
    "..#####.........",
    "................",
    "................",
};

test "a triangle's pixels, as worked out by hand" {
    var small: Small = .{};
    var target = try small.target(.{ .color = .{ .load = .keep } });
    defer target.deinit();
    const pipeline = Flat{ .viewport = whole_small };
    const vertices = [_]Flat.Vertex{
        .{ .position = at(1.5, 1.5), .color = 0xFF11_2233 },
        .{ .position = at(7.5, 1.5), .color = 0xFF11_2233 },
        .{ .position = at(1.5, 7.5), .color = 0xFF11_2233 },
        .{ .position = at(7.5, 7.5), .color = 0xFF44_5566 },
    };
    target.begin();
    try raster.draw(&target, &pipeline, &vertices, &[_]u16{ 0, 1, 2 });
    _ = target.finish();
    try small.expectShape(0xFF11_2233, &upper_left);

    small.pixels = @splat(background);
    target.begin();
    try raster.draw(&target, &pipeline, &vertices, &[_]u16{ 3, 2, 1 });
    _ = target.finish();
    try small.expectShape(0xFF44_5566, &lower_right);
}

test "a triangle facing away is culled, the other way round it is drawn" {
    var small: Small = .{};
    var target = try small.target(.{ .color = .{ .load = .keep } });
    defer target.deinit();
    const vertices = [_]Flat.Vertex{
        .{ .position = at(1.5, 1.5), .color = 0xFF11_2233 },
        .{ .position = at(7.5, 1.5), .color = 0xFF11_2233 },
        .{ .position = at(1.5, 7.5), .color = 0xFF11_2233 },
    };
    // Counter-clockwise on the surface: the back of a clockwise pipeline.
    const backwards = [_]u16{ 0, 2, 1 };
    const pipeline = Flat{ .viewport = whole_small };
    target.begin();
    try raster.draw(&target, &pipeline, &vertices, &backwards);
    try testing.expectEqual(@as(u32, 1), target.stats.dropped);
    try testing.expectEqual(@as(u32, 0), target.finish().tiles);

    const Both = raster.Pipeline(.{ .color = .flat, .cull = .none });
    const both = Both{ .viewport = whole_small };
    const same = [_]Both.Vertex{
        .{ .position = at(1.5, 1.5), .color = 0xFF11_2233 },
        .{ .position = at(7.5, 1.5), .color = 0xFF11_2233 },
        .{ .position = at(1.5, 7.5), .color = 0xFF11_2233 },
    };
    target.begin();
    try raster.draw(&target, &both, &same, &backwards);
    _ = target.finish();
    try small.expectShape(0xFF11_2233, &upper_left);
}

test "a triangle through the near plane is cut, one far past the sides is drawn" {
    var small: Small = .{};
    var target = try small.target(.{ .color = .{ .load = .keep } });
    defer target.deinit();
    const Plain = raster.Pipeline(.{ .cull = .none });
    const pipeline = Plain{ .viewport = whole_small, .color = 0xFF00_FF00 };
    // Half of it behind the eye: z from -1 to 1 down the surface. What is
    // left is the part with z >= 0, the lower half.
    const through = [_]Plain.Vertex{
        .{ .position = .{ -1, -1, -1 } },
        .{ .position = .{ 1, -1, -1 } },
        .{ .position = .{ -1, 1, 1 } },
        .{ .position = .{ 1, 1, 1 } },
    };
    target.begin();
    try raster.draw(&target, &pipeline, &through, &[_]u16{ 0, 1, 2, 1, 3, 2 });
    _ = target.finish();
    try testing.expectEqual(@as(u32, 2), target.stats.cut);
    for (0..Small.side) |y| for (0..Small.side) |x| {
        const want: u32 = if (y >= Small.side / 2) 0xFF00_FF00 else background;
        try testing.expectEqual(want, small.pixels[y * Small.side + x]);
    };

    // A triangle a thousand times the view's size covers all of it.
    small.pixels = @splat(background);
    const huge = [_]Plain.Vertex{
        .{ .position = .{ -1000, -1000, 0.5 } },
        .{ .position = .{ 3000, -1000, 0.5 } },
        .{ .position = .{ -1000, 3000, 0.5 } },
    };
    target.begin();
    try raster.draw(&target, &pipeline, &huge, &[_]u16{ 0, 1, 2 });
    _ = target.finish();
    try testing.expectEqual(@as(u32, 1), target.stats.cut);
    for (small.pixels) |pixel| try testing.expectEqual(@as(u32, 0xFF00_FF00), pixel);
}

test "triangles over many tiles, on threads, each pixel drawn by the right one" {
    var pixels: [width * height]u32 = @splat(background);
    var log: Log = .{};
    const area = Rect{ .x = 5, .y = 3, .width = 290, .height = 190 };
    var target = try Target.init(host(&log, true), surfaceOf(&pixels, .bgra32), area, .{ .color = .{ .clear = 0xFF00_0000 } });
    defer target.deinit();
    // A fan of eight triangles round the area's middle: every pixel of
    // the area is in exactly one, by its angle.
    const viewport = raster.Viewport{ .x = 5, .y = 3, .width = 290, .height = 190 };
    const pipeline = Flat{ .viewport = viewport };
    var vertices: [9]Flat.Vertex = undefined;
    vertices[0] = .{ .position = .{ 0.013, -0.027, 0.5 } };
    const corners = [8][2]f32{ .{ -3, -3 }, .{ 0, -3 }, .{ 3, -3 }, .{ 3, 0 }, .{ 3, 3 }, .{ 0, 3 }, .{ -3, 3 }, .{ -3, 0 } };
    for (corners, 1..) |corner, i| vertices[i] = .{ .position = .{ corner[0], corner[1], 0.5 }, .color = 0xFF00_0000 | @as(u32, @intCast(i)) };
    var indices: [24]u16 = undefined;
    for (0..8) |i| {
        indices[i * 3] = @intCast(1 + i);
        indices[i * 3 + 1] = @intCast(1 + (i + 1) % 8);
        indices[i * 3 + 2] = 0;
    }
    target.begin();
    try raster.draw(&target, &pipeline, &vertices, &indices);
    _ = target.finish();
    // Past the view but well inside the guard band: nothing is cut.
    try testing.expectEqual(@as(u32, 0), target.stats.cut);
    try testing.expectEqual(@as(u32, 8), target.stats.set_up);
    for (0..height) |y| for (0..width) |x| {
        const pixel = pixels[y * width + x];
        if (!inside(area, @intCast(x), @intCast(y))) {
            try testing.expectEqual(background, pixel);
            continue;
        }
        // Not the clear colour: some triangle drew it, and one only, as
        // replacing cannot show more.
        try testing.expect(pixel != 0xFF00_0000);
    };
}

/// Somewhere across `pixels` in clip space, on a pixel's corner or its
/// centre, every 6 pixels.
pub fn onGrid(r: std.Random, pixels: f32) f32 {
    const pixel = @as(f32, @floatFromInt(r.uintLessThan(u32, 8))) * 6 + 2 + if (r.boolean()) @as(f32, 0.5) else 0;
    return pixel * 2 / pixels - 1;
}

test "each row's run is the pixels inside all three edges, for triangles of every shape" {
    var pixels: [width * height]u32 = @splat(background);
    var log: Log = .{};
    const area = Rect{ .x = 3, .y = 2, .width = 290, .height = 193 };
    var target = try Target.init(host(&log, false), surfaceOf(&pixels, .bgra32), area, .{ .color = .{ .load = .keep } });
    defer target.deinit();
    const Any = raster.Pipeline(.{ .cull = .none });
    const viewport = raster.Viewport{ .x = 0, .y = 0, .width = width, .height = height };
    const pipeline = Any{ .viewport = viewport, .color = 0xFFFF_FFFF };
    var random = std.Random.DefaultPrng.init(0x5EED);
    const r = random.random();
    var round: u32 = 0;
    while (round < 400) : (round += 1) {
        // Small and thin ones, long ones, ones past the area's edges, and
        // ones on a grid of pixels, with edges along the rows and the
        // columns and on the pixels' centres.
        const reach: f32 = switch (round % 4) {
            0 => 0.05,
            1 => 0.4,
            2 => 1.6,
            else => 0,
        };
        var vertices: [3]Any.Vertex = undefined;
        const middle = [2]f32{ r.float(f32) * 2 - 1, r.float(f32) * 2 - 1 };
        for (&vertices) |*vertex| vertex.* = .{ .position = if (reach != 0) .{
            middle[0] + (r.float(f32) * 2 - 1) * reach,
            middle[1] + (r.float(f32) * 2 - 1) * reach,
            0.5,
        } else .{
            onGrid(r, width),
            onGrid(r, height),
            0.5,
        } };
        pixels = @splat(background);
        target.begin();
        try raster.draw(&target, &pipeline, &vertices, &[_]u16{ 0, 1, 2 });
        _ = target.finish();

        var projected: [3]setup.Projected = undefined;
        for (&projected, vertices) |*p, vertex| p.* = setup.project(.{ vertex.position[0], vertex.position[1], vertex.position[2], 1 }, viewport);
        const made = setup.onSurface(projected, .none, .clockwise, target.areaBounds());
        for (0..height) |y| for (0..width) |x| {
            var want = false;
            if (made) |triangle| if (inside(area, @intCast(x), @intCast(y))) {
                want = true;
                for (triangle.edges) |edge| {
                    if (edge.at(@intCast(x), @intCast(y)) < 0) want = false;
                }
            };
            const got = pixels[y * width + x] == 0xFFFF_FFFF;
            if (want != got) {
                std.debug.print("round {d}, pixel {d},{d}: {s}\n", .{ round, x, y, if (got) "drawn" else "not drawn" });
                return error.TestExpectedEqual;
            }
        };
    }
}

/// Triangles with depth, one colour each: the pixels each has where it is
/// nearest worked out from its edges and its depth's plane, as the
/// pipeline sets them up.
const Deep = raster.Pipeline(.{ .color = .flat, .cull = .none, .depth = .less });
const DeepEqual = raster.Pipeline(.{ .color = .flat, .cull = .none, .depth = .less_equal });

/// A triangle of `vertices` as setup makes it, to test pixels against,
/// and its depth.
const Made = struct { triangle: setup.Triangle, depth: setup.Depth };

fn madeOf(vertices: []const Deep.Vertex, viewport: raster.Viewport, target: *const Target) ?Made {
    var projected: [3]setup.Projected = undefined;
    for (&projected, vertices) |*p, vertex| p.* = setup.project(.{ vertex.position[0], vertex.position[1], vertex.position[2], 1 }, viewport);
    const triangle = setup.onSurface(projected, .none, .clockwise, target.areaBounds()) orelse return null;
    return .{ .triangle = triangle, .depth = .of(&triangle, &projected) };
}

/// The same vertices for another kind of pipeline.
fn verticesOf(comptime Kind: type, vertices: [6]Deep.Vertex) [6]Kind.Vertex {
    var made: [6]Kind.Vertex = undefined;
    for (&made, vertices) |*into, vertex| into.* = .{ .position = vertex.position, .color = vertex.color };
    return made;
}

fn covers(made: Made, x: u32, y: u32) bool {
    for (made.triangle.edges) |edge| {
        if (edge.at(x, y) < 0) return false;
    }
    return true;
}

test "the nearer of two triangles hides the other, whichever comes first" {
    var pixels: [width * height]u32 = @splat(background);
    var log: Log = .{};
    const area = Rect{ .x = 0, .y = 0, .width = width, .height = height };
    var target = try Target.init(host(&log, false), surfaceOf(&pixels, .bgra32), area, .{ .color = .{ .clear = 0xFF00_0000 }, .depth = .{ .used = true } });
    defer target.deinit();
    const viewport = raster.Viewport{ .x = 0, .y = 0, .width = width, .height = height };
    const pipeline = Deep{ .viewport = viewport };
    const near = 0xFFFF_0000;
    const far = 0xFF00_00FF;
    const vertices = [_]Deep.Vertex{
        .{ .position = .{ -0.9, -0.9, 0.25 }, .color = near },
        .{ .position = .{ 0.5, -0.7, 0.25 }, .color = near },
        .{ .position = .{ -0.6, 0.8, 0.25 }, .color = near },
        .{ .position = .{ -0.2, -0.5, 0.75 }, .color = far },
        .{ .position = .{ 0.9, 0.0, 0.75 }, .color = far },
        .{ .position = .{ -0.4, 0.9, 0.75 }, .color = far },
    };
    const a = madeOf(vertices[0..3], viewport, &target).?;
    const b = madeOf(vertices[3..6], viewport, &target).?;
    for ([_][6]u16{ .{ 0, 1, 2, 3, 4, 5 }, .{ 3, 4, 5, 0, 1, 2 } }) |indices| {
        target.begin();
        try raster.draw(&target, &pipeline, &vertices, &indices);
        _ = target.finish();
        var both: u32 = 0;
        for (0..height) |y| for (0..width) |x| {
            const in_a = covers(a, @intCast(x), @intCast(y));
            const in_b = covers(b, @intCast(x), @intCast(y));
            if (in_a and in_b) both += 1;
            const want: u32 = if (in_a) near else if (in_b) far else 0xFF00_0000;
            try testing.expectEqual(want, pixels[y * width + x]);
        };
        try testing.expect(both > 1000);
    }
}

test "of two as near the first is kept by less, the second by less or equal" {
    var pixels: [width * height]u32 = @splat(background);
    var log: Log = .{};
    const area = Rect{ .x = 0, .y = 0, .width = width, .height = height };
    var target = try Target.init(host(&log, false), surfaceOf(&pixels, .bgra32), area, .{ .depth = .{ .used = true } });
    defer target.deinit();
    const viewport = raster.Viewport{ .x = 0, .y = 0, .width = width, .height = height };
    const first = 0xFF11_1111;
    const second = 0xFF22_2222;
    // Sloping in depth, so that each pixel has a depth of its own.
    const vertices = [_]Deep.Vertex{
        .{ .position = .{ -0.9, -0.9, 0.1 }, .color = first },
        .{ .position = .{ 0.9, -0.8, 0.6 }, .color = first },
        .{ .position = .{ 0.1, 0.9, 0.9 }, .color = first },
        .{ .position = .{ -0.9, -0.9, 0.1 }, .color = second },
        .{ .position = .{ 0.9, -0.8, 0.6 }, .color = second },
        .{ .position = .{ 0.1, 0.9, 0.9 }, .color = second },
    };
    const indices = [_]u16{ 0, 1, 2, 3, 4, 5 };
    const made = madeOf(vertices[0..3], viewport, &target).?;
    inline for (.{ Deep, DeepEqual }, .{ first, second }) |Kind, kept| {
        const pipeline = Kind{ .viewport = viewport };
        target.begin();
        try raster.draw(&target, &pipeline, &verticesOf(Kind, vertices), &indices);
        _ = target.finish();
        for (0..height) |y| for (0..width) |x| {
            const want: u32 = if (covers(made, @intCast(x), @intCast(y))) kept else 0xFF00_0000;
            try testing.expectEqual(want, pixels[y * width + x]);
        };
    }
}

test "two triangles through each other: each pixel the nearer one's" {
    var pixels: [width * height]u32 = @splat(background);
    var log: Log = .{};
    const area = Rect{ .x = 5, .y = 3, .width = 280, .height = 190 };
    var target = try Target.init(host(&log, true), surfaceOf(&pixels, .bgra32), area, .{ .color = .{ .clear = 0xFF00_0000 }, .depth = .{ .used = true } });
    defer target.deinit();
    const viewport = raster.Viewport{ .x = 0, .y = 0, .width = width, .height = height };
    const red = 0xFFFF_0000;
    const blue = 0xFF00_00FF;
    // Red nears the left, blue the right; they cross where x is 0.
    const vertices = [_]Deep.Vertex{
        .{ .position = .{ -0.9, -0.8, 0.2 }, .color = red },
        .{ .position = .{ 0.9, -0.8, 0.8 }, .color = red },
        .{ .position = .{ 0.0, 0.9, 0.5 }, .color = red },
        .{ .position = .{ -0.9, 0.8, 0.8 }, .color = blue },
        .{ .position = .{ 0.0, -0.9, 0.5 }, .color = blue },
        .{ .position = .{ 0.9, 0.8, 0.2 }, .color = blue },
    };
    const a = madeOf(vertices[0..3], viewport, &target).?;
    const b = madeOf(vertices[3..6], viewport, &target).?;
    inline for (.{ Deep, DeepEqual }) |Kind| {
        const pipeline = Kind{ .viewport = viewport };
        target.begin();
        try raster.draw(&target, &pipeline, &verticesOf(Kind, vertices), &[_]u16{ 0, 1, 2, 3, 4, 5 });
        _ = target.finish();
        var reds: u32 = 0;
        var blues: u32 = 0;
        for (0..height) |y| for (0..width) |x| {
            const at_x: u32 = @intCast(x);
            const at_y: u32 = @intCast(y);
            const got = pixels[y * width + x];
            if (!inside(area, at_x, at_y)) {
                try testing.expectEqual(background, got);
                continue;
            }
            const in_a = covers(a, at_x, at_y);
            const in_b = covers(b, at_x, at_y);
            const z_a = a.depth.plane.at(@floatFromInt(x), @floatFromInt(y));
            const z_b = b.depth.plane.at(@floatFromInt(x), @floatFromInt(y));
            // Where the two are within a unit of each other, either.
            if (in_a and in_b and @abs(z_a - z_b) <= 1) continue;
            const want: u32 = if (in_a and (!in_b or z_a < z_b)) red else if (in_b) blue else 0xFF00_0000;
            if (want != got) {
                std.debug.print("pixel {d},{d}: {x}, not {x}; depths {d} {d}\n", .{ x, y, got, want, z_a, z_b });
                return error.TestExpectedEqual;
            }
            if (in_a and in_b) {
                if (got == red) reds += 1 else blues += 1;
            }
        };
        try testing.expect(reds > 1000 and blues > 1000);
    }
}
