// SPDX-License-Identifier: MIT
//! A canvas: the caller's pens and the drawing's working memory for them -
//! the coverage of a band of rows, and the points of the contour being
//! drawn.
//!
//! **Bands.** The coverage is summed a band of rows at a time, not over the
//! whole canvas: a fill or a stroke is drawn once a band, each time from
//! its path, and laid down before the next. A band holds at most
//! `band_floats` floats (512 KiB), so a canvas of 360 by 360 - the
//! largest a Lottie frame is drawn - is one band, and one of 1024 by 1024
//! is nine of 113 rows rather than 4 MiB of coverage at once. Only the
//! bands the path can reach are drawn.
//!
//! **Laid down by coverage**: a pixel's share of the shape times the
//! paint's opacity is how much of the paint goes over what the pen held,
//! the pens being 0xAARRGGBB and not premultiplied.

const sdk = @import("sdk");
const vector = sdk.vector;
const Pen = sdk.graphics.Pen;
const P = vector.Point;
const Matrix = vector.Matrix;
const memory_ = @import("memory.zig");
const Memory = memory_.Memory;
const List = memory_.List;
const Path = @import("path.zig").Path;
const flatten = @import("flatten.zig");
const coverage_ = @import("coverage.zig");
const Coverage = coverage_.Coverage;
const stroke_ = @import("stroke.zig");

/// The most floats a band of coverage holds.
pub const band_floats: usize = 128 * 1024;

pub const Canvas = struct {
    memory: Memory,
    width: u32,
    height: u32,
    pens: ?[*]Pen = null,
    bytes_per_row: u32 = 0,
    /// A band's coverage, cleared between draws.
    acc: []f32,
    band_rows: u32,
    /// The points of the contour being drawn.
    points: List(P) = .{},

    /// A canvas `width` by `height`, its band cleared; null without the
    /// memory, or for a size of nothing.
    pub fn create(memory: Memory, width: u32, height: u32) ?*Canvas {
        if (width == 0 or height == 0 or width > 1 << 20 or height > 1 << 20) return null;
        const stride: usize = @as(usize, width) + 2;
        const rows: u32 = @intCast(@min(@max(band_floats / stride, 1), height));
        const acc = memory.alloc(f32, stride * rows) orelse return null;
        @memset(acc, 0);
        const canvas = memory.create(Canvas) orelse {
            memory.free(f32, acc);
            return null;
        };
        canvas.* = .{ .memory = memory, .width = width, .height = height, .acc = acc, .band_rows = rows };
        return canvas;
    }

    pub fn destroy(canvas: *Canvas) void {
        const memory = canvas.memory;
        memory.free(f32, canvas.acc);
        canvas.points.deinit(memory);
        memory.destroy(Canvas, canvas);
    }

    pub fn setPens(canvas: *Canvas, pens: ?[*]Pen, bytes_per_row: u32) void {
        canvas.pens = pens;
        canvas.bytes_per_row = if (bytes_per_row == 0) canvas.width * 4 else bytes_per_row;
    }

    /// The path filled through `matrix` in `paint`, by `rule`.
    pub fn fill(canvas: *Canvas, path: *const Path, matrix: Matrix, paint: *const vector.Paint, rule: u32) i32 {
        var result: i32 = if (path.failed) vector.VECTORERR_NOMEM else vector.VECTOR_OK;
        if (canvas.pens == null) return result;
        const span = canvas.rowsOf(path, matrix, 0) orelse return result;
        var top = span.first;
        while (top < span.end) : (top += canvas.band_rows) {
            var coverage = canvas.band(top);
            if (!flatten.contours(path, flatten.Flatten.fill(matrix), &canvas.points, canvas.memory, &coverage, filled)) result = vector.VECTORERR_NOMEM;
            canvas.lay(&coverage, paint, rule == vector.RULE_EVENODD);
        }
        return result;
    }

    /// The path stroked in its own units, then through `matrix`, in
    /// `paint`.
    pub fn stroke(canvas: *Canvas, path: *const Path, matrix: Matrix, paint: *const vector.Paint, how: *const vector.Stroke) i32 {
        var result: i32 = if (path.failed) vector.VECTORERR_NOMEM else vector.VECTOR_OK;
        if (canvas.pens == null) return result;
        const pieces = stroke_.How.of(how);
        if (pieces.half * matrix.size() <= 0.01) return result;
        // As far as a piece reaches past the path: a miter at its longest,
        // a square cap's corner, through the matrix at its most stretching.
        const reach = pieces.half * stretch(matrix) * @max(pieces.miter_limit, 1.5) + 1;
        const span = canvas.rowsOf(path, matrix, reach) orelse return result;
        var top = span.first;
        while (top < span.end) : (top += canvas.band_rows) {
            var coverage = canvas.band(top);
            var stroker = Stroker{ .sink = stroke_.Sink.of(&coverage, matrix), .how = pieces };
            if (!flatten.contours(path, flatten.Flatten.stroke(matrix), &canvas.points, canvas.memory, &stroker, Stroker.emit)) result = vector.VECTORERR_NOMEM;
            canvas.lay(&coverage, paint, false);
        }
        return result;
    }

    fn band(canvas: *Canvas, top: u32) Coverage {
        return .{
            .acc = canvas.acc.ptr,
            .width = canvas.width,
            .height = canvas.height,
            .band_top = top,
            .band_end = @min(top + canvas.band_rows, canvas.height),
        };
    }

    const Span = struct { first: u32, end: u32 };

    /// The rows the path's points reach through `matrix`, `reach` pixels
    /// further each way, on the canvas; null for none. A curve keeps
    /// within its control points, so they are enough.
    fn rowsOf(canvas: *const Canvas, path: *const Path, matrix: Matrix, reach: f32) ?Span {
        var low: f32 = std.math.inf(f32);
        var high: f32 = -std.math.inf(f32);
        for (path.points.items()) |p| {
            const y = matrix.apply(p).y;
            if (y != y) continue;
            low = @min(low, y);
            high = @max(high, y);
        }
        if (!(low <= high)) return null;
        const rows: f32 = @floatFromInt(canvas.height);
        const first = @floor(@min(@max(low - reach, 0), rows));
        const end = @ceil(@min(@max(high + reach + 1, 0), rows));
        if (first >= end) return null;
        return .{ .first = @intFromFloat(first), .end = @intFromFloat(end) };
    }

    /// What the band holds laid onto the pens, and the band cleared where
    /// it was.
    fn lay(canvas: *Canvas, coverage: *Coverage, paint: *const vector.Paint, even_odd: bool) void {
        if (!coverage.touched()) return coverage.forget();
        const colour = paint.colour;
        const red = colour.r * 255;
        const green = colour.g * 255;
        const blue = colour.b * 255;
        const opacity = @min(@max(paint.opacity * colour.a, 0), 1);
        const stride_width = coverage.stride();
        var y = coverage.top;
        while (y < coverage.bottom) : (y += 1) {
            const row = coverage.row(y);
            const pens = canvas.rowOf(y);
            var sum: f32 = 0;
            var x = coverage.left;
            while (x < stride_width) : (x += 1) {
                sum += row[x];
                row[x] = 0;
                if (x >= canvas.width) continue;
                var cover = @abs(sum);
                if (even_odd) {
                    cover -= 2 * @floor(cover / 2);
                    if (cover > 1) cover = 2 - cover;
                } else if (cover > 1) cover = 1;
                const a = cover * opacity;
                if (a < 1.0 / 512.0) continue;
                pens[x] = over(pens[x], red, green, blue, a);
            }
        }
        coverage.forget();
    }

    fn rowOf(canvas: *const Canvas, y: u32) [*]Pen {
        return @ptrCast(@alignCast(@as([*]u8, @ptrCast(canvas.pens.?)) + @as(usize, y) * canvas.bytes_per_row));
    }
};

/// How far the matrix stretches a length at most - its largest singular
/// value, or a little over: the root of its four scales' squares.
fn stretch(m: Matrix) f32 {
    return @sqrt(m.a * m.a + m.b * m.b + m.c * m.c + m.d * m.d);
}

fn filled(coverage: *Coverage, points: []const P, closed: bool) void {
    _ = closed;
    coverage.polygon(points);
}

const Stroker = struct {
    sink: stroke_.Sink,
    how: stroke_.How,

    fn emit(stroker: *Stroker, points: []const P, closed: bool) void {
        stroke_.contour(&stroker.sink, points, closed, stroker.how);
    }
};

/// A colour at `a` laid over a pen.
pub fn over(pen: Pen, red: f32, green: f32, blue: f32, a: f32) Pen {
    const below_alpha = @as(f32, @floatFromInt(pen >> 24)) / 255;
    const out_alpha = a + below_alpha * (1 - a);
    if (out_alpha <= 0) return 0;
    const below = below_alpha * (1 - a);
    const r = (red * a + @as(f32, @floatFromInt((pen >> 16) & 0xFF)) * below) / out_alpha;
    const g = (green * a + @as(f32, @floatFromInt((pen >> 8) & 0xFF)) * below) / out_alpha;
    const b = (blue * a + @as(f32, @floatFromInt(pen & 0xFF)) * below) / out_alpha;
    return @as(Pen, byte(out_alpha * 255)) << 24 | @as(Pen, byte(r)) << 16 | @as(Pen, byte(g)) << 8 | byte(b);
}

fn byte(value: f32) u8 {
    return @intFromFloat(@min(@max(value + 0.5, 0), 255));
}

const std = @import("std");

// --- tests: lottie.datatype's, moved with the code --------------------------

const testing = std.testing;
const test_memory = memory_.test_memory;

fn solid(r: f32, g: f32, b: f32) vector.Paint {
    return .{ .colour = .{ .r = r, .g = g, .b = b } };
}

test "a square half off the canvas is filled where it is on it" {
    const canvas = Canvas.create(test_memory, 8, 8).?;
    defer canvas.destroy();
    var pens: [64]Pen = @splat(0);
    canvas.setPens(&pens, 32);
    const path = Path.create(test_memory).?;
    defer path.destroy();
    path.moveTo(.{ .x = -4, .y = 2 });
    path.lineTo(.{ .x = 4, .y = 2 });
    path.lineTo(.{ .x = 4, .y = 6 });
    path.lineTo(.{ .x = -4, .y = 6 });
    path.close();
    try testing.expectEqual(vector.VECTOR_OK, canvas.fill(path, .{}, &solid(1, 0, 0), vector.RULE_NONZERO));
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[3 * 8 + 0]);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[5 * 8 + 3]);
    try testing.expectEqual(@as(Pen, 0), pens[3 * 8 + 4]);
    try testing.expectEqual(@as(Pen, 0), pens[1 * 8 + 0]);
    for (canvas.acc) |left| try testing.expectEqual(@as(f32, 0), left);
}

test "a hole by the even-odd rule, none by non-zero" {
    const canvas = Canvas.create(test_memory, 10, 10).?;
    defer canvas.destroy();
    var pens: [100]Pen = @splat(0);
    canvas.setPens(&pens, 40);
    const path = Path.create(test_memory).?;
    defer path.destroy();
    for ([_][4]P{
        .{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } },
        .{ .{ .x = 3, .y = 3 }, .{ .x = 7, .y = 3 }, .{ .x = 7, .y = 7 }, .{ .x = 3, .y = 7 } },
    }) |square| {
        path.moveTo(square[0]);
        for (square[1..]) |p| path.lineTo(p);
        path.close();
    }
    _ = canvas.fill(path, .{}, &solid(0, 0, 1), vector.RULE_EVENODD);
    try testing.expectEqual(@as(Pen, 0), pens[5 * 10 + 5]);
    try testing.expectEqual(@as(Pen, 0xFF0000FF), pens[1 * 10 + 1]);
    _ = canvas.fill(path, .{}, &solid(0, 1, 0), vector.RULE_NONZERO);
    try testing.expectEqual(@as(Pen, 0xFF00FF00), pens[5 * 10 + 5]);
}

test "a stroke covers its width" {
    const canvas = Canvas.create(test_memory, 20, 20).?;
    defer canvas.destroy();
    var pens: [400]Pen = @splat(0);
    canvas.setPens(&pens, 80);
    const path = Path.create(test_memory).?;
    defer path.destroy();
    path.moveTo(.{ .x = 2, .y = 10 });
    path.lineTo(.{ .x = 10, .y = 10 });
    path.lineTo(.{ .x = 10, .y = 18 });
    const how = vector.Stroke{ .width = 4, .join = vector.JOIN_MITER, .cap = vector.CAP_SQUARE };
    _ = canvas.stroke(path, .{}, &solid(1, 1, 1), &how);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[9 * 20 + 5]);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[10 * 20 + 1]);
    // The miter's outer corner.
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[8 * 20 + 11]);
    try testing.expectEqual(@as(Pen, 0), pens[5 * 20 + 5]);
    try testing.expectEqual(@as(Pen, 0), pens[14 * 20 + 5]);
}

// --- tests: what the library adds ----------------------------------------------

test "a canvas taller than a band draws what one band would" {
    // 4094 pixels wide: a band of 32 rows; 100 rows are four bands.
    const wide: u32 = band_floats / 32 - 2;
    const canvas = Canvas.create(test_memory, wide, 100).?;
    defer canvas.destroy();
    try testing.expectEqual(@as(u32, 32), canvas.band_rows);
    const pens = test_memory.alloc(Pen, @as(usize, wide) * 100).?;
    defer test_memory.free(Pen, pens);
    @memset(pens, 0);
    canvas.setPens(pens.ptr, wide * 4);
    const path = Path.create(test_memory).?;
    defer path.destroy();
    path.moveTo(.{ .x = 3.25, .y = 1.5 });
    path.cubicTo(.{ .x = 90, .y = 10 }, .{ .x = 10, .y = 90 }, .{ .x = 80.5, .y = 97.25 });
    path.lineTo(.{ .x = 1, .y = 60 });
    path.close();
    _ = canvas.fill(path, .{}, &solid(0, 0.5, 1), vector.RULE_NONZERO);
    // The same on a canvas of one band, 90 wide.
    const small = Canvas.create(test_memory, 90, 100).?;
    defer small.destroy();
    try testing.expectEqual(@as(u32, 100), small.band_rows);
    var own: [90 * 100]Pen = @splat(0);
    small.setPens(&own, 90 * 4);
    _ = small.fill(path, .{}, &solid(0, 0.5, 1), vector.RULE_NONZERO);
    var painted: u32 = 0;
    for (0..100) |y| for (0..90) |x| {
        try testing.expectEqual(own[y * 90 + x], pens[y * wide + x]);
        if (own[y * 90 + x] != 0) painted += 1;
    };
    try testing.expect(painted > 2000);
    for (canvas.acc) |left| try testing.expectEqual(@as(f32, 0), left);
}

test "a path through a matrix: scaled, moved, a stroke stretched with it" {
    const canvas = Canvas.create(test_memory, 40, 40).?;
    defer canvas.destroy();
    var pens: [1600]Pen = @splat(0);
    canvas.setPens(&pens, 160);
    const path = Path.create(test_memory).?;
    defer path.destroy();
    // A unit square, four times as large, moved 10 right and 10 down.
    path.moveTo(.{ .x = 0, .y = 0 });
    path.lineTo(.{ .x = 1, .y = 0 });
    path.lineTo(.{ .x = 1, .y = 1 });
    path.lineTo(.{ .x = 0, .y = 1 });
    path.close();
    const m = Matrix.translate(10, 10).then(Matrix.scale(4, 4));
    _ = canvas.fill(path, m, &solid(1, 0, 0), vector.RULE_NONZERO);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[11 * 40 + 11]);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[13 * 40 + 13]);
    try testing.expectEqual(@as(Pen, 0), pens[14 * 40 + 14]);
    // A line down, stroked half a unit wide and drawn eight times as wide
    // as it is tall: the stroke is 4 pixels from side to side.
    @memset(&pens, 0);
    path.clear();
    path.moveTo(.{ .x = 1, .y = 2 });
    path.lineTo(.{ .x = 1, .y = 4 });
    _ = canvas.stroke(path, Matrix.scale(8, 1), &solid(1, 1, 1), &.{ .width = 0.5 });
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[3 * 40 + 6]);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[3 * 40 + 9]);
    try testing.expectEqual(@as(Pen, 0), pens[3 * 40 + 11]);
    try testing.expectEqual(@as(Pen, 0), pens[3 * 40 + 4]);
}
