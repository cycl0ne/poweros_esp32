// SPDX-License-Identifier: MIT
//! Paths into pixels: curves flattened into contours of points, filled
//! or stroked by measuring how much of each pixel they cover, and that
//! coverage laid onto the frame in one colour.
//!
//! **Coverage is measured by signed area.** Every line of a contour adds
//! to an accumulation buffer, for each row it crosses, the share of each
//! pixel it passes that lies to its right - positive going down,
//! negative going up. Summing a row from the left then gives at each
//! pixel the winding of the paths over it, fractional at their edges:
//! its size clamped to 1 is the coverage of the non-zero rule, its
//! distance from the nearest even number that of the even-odd rule.
//! Only the rows and columns lines reached are summed, and they are left
//! cleared for the next.
//!
//! A line outside the frame on the left adds its whole share to the
//! first column, one on the right nothing: lines are cut where they
//! cross either side and their pieces held to it.
//!
//! **A stroke is pieces, every one wound the same way**: a quadrilateral
//! a segment, a triangle or quadrilateral at each corner (bevel or
//! miter) or a disc (round), and at an open path's ends a square or a
//! disc. Where pieces overlap their windings add up and the non-zero
//! rule makes one shape of them.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const Pen = graphics.Pen;

pub const P = struct {
    x: f32,
    y: f32,

    fn add(a: P, b: P) P {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    fn sub(a: P, b: P) P {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    fn times(a: P, s: f32) P {
        return .{ .x = a.x * s, .y = a.y * s };
    }
};

/// An affine transform: x' = a x + c y + e, y' = b x + d y + f.
pub const Matrix = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    pub fn apply(m: Matrix, p: P) P {
        return .{ .x = m.a * p.x + m.c * p.y + m.e, .y = m.b * p.x + m.d * p.y + m.f };
    }

    /// `m` after `n`: n is applied first.
    pub fn then(m: Matrix, n: Matrix) Matrix {
        return .{
            .a = m.a * n.a + m.c * n.b,
            .b = m.b * n.a + m.d * n.b,
            .c = m.a * n.c + m.c * n.d,
            .d = m.b * n.c + m.d * n.d,
            .e = m.a * n.e + m.c * n.f + m.e,
            .f = m.b * n.e + m.d * n.f + m.f,
        };
    }

    pub fn translate(x: f32, y: f32) Matrix {
        return .{ .e = x, .f = y };
    }

    pub fn scale(x: f32, y: f32) Matrix {
        return .{ .a = x, .d = y };
    }

    /// Clockwise on the screen, in degrees.
    pub fn rotate(degrees: f32) Matrix {
        const radians = degrees * (3.14159265 / 180.0);
        const cos = @cos(radians);
        const sin = @sin(radians);
        return .{ .a = cos, .b = sin, .c = -sin, .d = cos };
    }

    /// How much it scales a length, on average.
    pub fn size(m: Matrix) f32 {
        return @sqrt(@abs(m.a * m.d - m.b * m.c));
    }
};

/// Flattened contours: points, and for each contour where it ends and
/// whether it is closed.
pub const Outline = struct {
    points: []P,
    ends: []u32,
    closed: []bool,
    point_count: u32 = 0,
    contour_count: u32 = 0,
    /// Where the contour being built started.
    start: u32 = 0,

    pub fn reset(outline: *Outline) void {
        outline.point_count = 0;
        outline.contour_count = 0;
        outline.start = 0;
    }

    pub fn moveTo(outline: *Outline, p: P) void {
        outline.start = outline.point_count;
        outline.lineTo(p);
    }

    /// A point onto the contour being built; one more than there is room
    /// for is dropped, and the path drawn as far as it went.
    pub fn lineTo(outline: *Outline, p: P) void {
        if (outline.point_count == outline.points.len) return;
        outline.points[outline.point_count] = p;
        outline.point_count += 1;
    }

    /// A cubic curve from the last point: lines enough that none strays
    /// from it by more than a quarter of a pixel.
    pub fn cubicTo(outline: *Outline, p1: P, p2: P, p3: P) void {
        if (outline.point_count == 0) return;
        const p0 = outline.points[outline.point_count - 1];
        const d1 = p0.sub(p1.times(2)).add(p2);
        const d2 = p1.sub(p2.times(2)).add(p3);
        const deviation = @max(@sqrt(d1.x * d1.x + d1.y * d1.y), @sqrt(d2.x * d2.x + d2.y * d2.y));
        if (deviation < 0.1) return outline.lineTo(p3);
        const steps: u32 = @min(1 + @as(u32, @intFromFloat(@sqrt(deviation * 3.0))), 64);
        var i: u32 = 1;
        while (i <= steps) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            const u = 1 - t;
            const a = u * u * u;
            const b = 3 * u * u * t;
            const c = 3 * u * t * t;
            const d = t * t * t;
            outline.lineTo(.{
                .x = a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                .y = a * p0.y + b * p1.y + c * p2.y + d * p3.y,
            });
        }
    }

    /// The contour being built ended.
    pub fn end(outline: *Outline, closed: bool) void {
        if (outline.point_count == outline.start) return;
        if (outline.contour_count == outline.ends.len) {
            outline.point_count = outline.start;
            return;
        }
        outline.ends[outline.contour_count] = outline.point_count;
        outline.closed[outline.contour_count] = closed;
        outline.contour_count += 1;
        outline.start = outline.point_count;
    }

    fn contour(outline: *const Outline, n: u32) []const P {
        const from = if (n == 0) 0 else outline.ends[n - 1];
        return outline.points[from..outline.ends[n]];
    }
};

/// How a stroke's corners and open ends are drawn.
pub const Join = enum { miter, round, bevel };
pub const Cap = enum { butt, round, square };

pub const Stroke = struct {
    half: f32,
    join: Join = .miter,
    cap: Cap = .butt,
    /// The longest miter, in half widths.
    miter_limit: f32 = 4,
};

/// A colour, 0 to 1 each.
pub const Colour = struct { r: f32, g: f32, b: f32 };

/// The frame being drawn on.
pub const Canvas = struct {
    pens: [*]Pen,
    bytes_per_row: u32,
    width: u32,
    height: u32,

    fn row(canvas: Canvas, y: u32) [*]Pen {
        return @ptrCast(@alignCast(@as([*]u8, @ptrCast(canvas.pens)) + y * canvas.bytes_per_row));
    }
};

/// The accumulation buffer: rows of `width + 2`, so a line on the right
/// edge still has somewhere to put what lies right of it; and the rows
/// and first column touched since it was last laid down.
pub const Raster = struct {
    acc: [*]f32,
    width: u32,
    height: u32,
    top: u32 = 0xFFFF_FFFF,
    bottom: u32 = 0,
    left: u32 = 0xFFFF_FFFF,

    pub fn stride(raster: *const Raster) u32 {
        return raster.width + 2;
    }

    /// How many floats a buffer for a frame this size holds.
    pub fn floats(width: u32, height: u32) usize {
        return @as(usize, width + 2) * height;
    }

    /// A line, cut at the frame's sides.
    pub fn line(raster: *Raster, p0: P, p1: P) void {
        if (p0.y == p1.y) return;
        if (p0.y != p0.y or p1.y != p1.y or p0.x != p0.x or p1.x != p1.x) return;
        const right: f32 = @floatFromInt(raster.width);
        for ([_]f32{ 0, right }) |side| {
            if ((p0.x < side) != (p1.x < side) and p0.x != side and p1.x != side) {
                const t = (side - p0.x) / (p1.x - p0.x);
                const middle = P{ .x = side, .y = p0.y + t * (p1.y - p0.y) };
                raster.line(p0, middle);
                raster.line(middle, p1);
                return;
            }
        }
        raster.inside(.{ .x = @min(@max(p0.x, 0), right), .y = p0.y }, .{ .x = @min(@max(p1.x, 0), right), .y = p1.y });
    }

    fn add(raster: *Raster, row_start: usize, x: i32, value: f32) void {
        if (x < 0 or x >= raster.stride()) return;
        raster.acc[row_start + @as(usize, @intCast(x))] += value;
    }

    /// A line between 0 and the width: its share of each pixel of each
    /// row it crosses.
    fn inside(raster: *Raster, p0: P, p1: P) void {
        const dir: f32 = if (p0.y < p1.y) 1 else -1;
        const a = if (p0.y < p1.y) p0 else p1;
        const b = if (p0.y < p1.y) p1 else p0;
        const dxdy = (b.x - a.x) / (b.y - a.y);
        const rows: f32 = @floatFromInt(raster.height);
        var x = a.x;
        var y_top = a.y;
        if (y_top < 0) {
            x -= y_top * dxdy;
            y_top = 0;
        }
        const y_bottom = @min(b.y, rows);
        if (y_top >= y_bottom) return;
        var y: u32 = @intFromFloat(@floor(y_top));
        const y_end: u32 = @intFromFloat(@ceil(y_bottom));
        raster.top = @min(raster.top, y);
        raster.bottom = @max(raster.bottom, y_end);
        const leftmost: u32 = @intFromFloat(@floor(@max(@min(a.x, b.x), 0)));
        raster.left = @min(raster.left, leftmost);
        const stride_width = raster.stride();
        while (y < y_end) : (y += 1) {
            const row_start = @as(usize, y) * stride_width;
            const yf: f32 = @floatFromInt(y);
            const dy = @min(yf + 1, y_bottom) - @max(yf, y_top);
            const x_next = x + dxdy * dy;
            const d = dy * dir;
            const x0 = @min(x, x_next);
            const x1 = @max(x, x_next);
            const x0_floor = @floor(x0);
            const x0i: i32 = @intFromFloat(x0_floor);
            const x1_ceil = @ceil(x1);
            const x1i: i32 = @intFromFloat(x1_ceil);
            if (x1i <= x0i + 1) {
                const xmf = 0.5 * (x + x_next) - x0_floor;
                raster.add(row_start, x0i, d - d * xmf);
                raster.add(row_start, x0i + 1, d * xmf);
            } else {
                const s = 1 / (x1 - x0);
                const x0f = x0 - x0_floor;
                const a0 = 0.5 * s * (1 - x0f) * (1 - x0f);
                const x1f = x1 - x1_ceil + 1;
                const am = 0.5 * s * x1f * x1f;
                raster.add(row_start, x0i, d * a0);
                if (x1i == x0i + 2) {
                    raster.add(row_start, x0i + 1, d * (1 - a0 - am));
                } else {
                    const a1 = s * (1.5 - x0f);
                    raster.add(row_start, x0i + 1, d * (a1 - a0));
                    var xi = x0i + 2;
                    while (xi < x1i - 1) : (xi += 1) raster.add(row_start, xi, d * s);
                    const a2 = a1 + @as(f32, @floatFromInt(x1i - x0i - 3)) * s;
                    raster.add(row_start, x1i - 1, d * (1 - a2 - am));
                }
                raster.add(row_start, x1i, d * am);
            }
            x = x_next;
        }
    }

    /// A closed polygon, as it is wound.
    fn polygon(raster: *Raster, points: []const P) void {
        if (points.len < 2) return;
        var previous = points[points.len - 1];
        for (points) |p| {
            raster.line(previous, p);
            previous = p;
        }
    }

    /// A convex polygon, wound the one way every piece of a stroke is.
    fn piece(raster: *Raster, points: []const P) void {
        var twice_area: f32 = 0;
        var previous = points[points.len - 1];
        for (points) |p| {
            twice_area += previous.x * p.y - p.x * previous.y;
            previous = p;
        }
        if (twice_area >= 0) return raster.polygon(points);
        var i = points.len;
        previous = points[0];
        while (i > 0) {
            i -= 1;
            raster.line(previous, points[i]);
            previous = points[i];
        }
    }

    fn disc(raster: *Raster, centre: P, radius: f32) void {
        if (radius <= 0.05) return;
        var sides: u32 = @intFromFloat(@ceil(radius * 2));
        sides = @min(@max(sides, 8), 64);
        var points: [64]P = undefined;
        for (0..sides) |i| {
            const angle = @as(f32, @floatFromInt(i)) * (2 * 3.14159265) / @as(f32, @floatFromInt(sides));
            points[i] = .{ .x = centre.x + radius * @cos(angle), .y = centre.y + radius * @sin(angle) };
        }
        raster.piece(points[0..sides]);
    }

    /// The outline's contours filled.
    pub fn fill(raster: *Raster, outline: *const Outline) void {
        for (0..outline.contour_count) |n| raster.polygon(outline.contour(@intCast(n)));
    }

    /// The outline's contours stroked.
    pub fn stroke(raster: *Raster, outline: *const Outline, how: Stroke) void {
        if (how.half <= 0.01) return;
        for (0..outline.contour_count) |n| {
            raster.strokeContour(outline.contour(@intCast(n)), outline.closed[n], how);
        }
    }

    fn strokeContour(raster: *Raster, all: []const P, closed: bool, how: Stroke) void {
        // A point on the last one is passed over.
        var first: ?P = null;
        var first_direction: P = .{ .x = 0, .y = 0 };
        var previous: ?P = null;
        var direction: P = .{ .x = 0, .y = 0 };
        var segments: u32 = 0;
        for (all) |p| {
            const from = previous orelse {
                previous = p;
                first = p;
                continue;
            };
            const along = unit(p.sub(from)) orelse continue;
            raster.segment(from, p, along, how.half);
            if (segments > 0) raster.corner(from, direction, along, how) else first_direction = along;
            segments += 1;
            direction = along;
            previous = p;
        }
        const start = first orelse return;
        const last = previous.?;
        if (segments == 0) {
            if (how.cap == .round) raster.disc(start, how.half);
            return;
        }
        if (closed) {
            if (unit(start.sub(last))) |along| {
                raster.segment(last, start, along, how.half);
                raster.corner(last, direction, along, how);
                raster.corner(start, along, first_direction, how);
            } else {
                raster.corner(start, direction, first_direction, how);
            }
            return;
        }
        raster.end(start, first_direction.times(-1), how);
        raster.end(last, direction, how);
    }

    fn segment(raster: *Raster, from: P, to: P, along: P, half: f32) void {
        const normal = P{ .x = -along.y * half, .y = along.x * half };
        raster.piece(&.{ from.add(normal), to.add(normal), to.sub(normal), from.sub(normal) });
    }

    /// The corner at `at` between a segment going `in` and one going `out`.
    fn corner(raster: *Raster, at: P, in: P, out: P, how: Stroke) void {
        const dot = in.x * out.x + in.y * out.y;
        const cross = in.x * out.y - in.y * out.x;
        // Almost straight on: a bevel fills what little gap there is.
        const join: Join = if (dot > 0.95) .bevel else how.join;
        const half = how.half;
        var n1 = P{ .x = -in.y * half, .y = in.x * half };
        var n2 = P{ .x = -out.y * half, .y = out.x * half };
        switch (join) {
            .round => raster.disc(at, half),
            .bevel => {
                if (@abs(cross) < 1e-6) return;
                raster.piece(&.{ at, at.add(n1), at.add(n2) });
                raster.piece(&.{ at, at.sub(n1), at.sub(n2) });
            },
            .miter => {
                if (@abs(cross) < 1e-6) return;
                // The outer side is the one the path turns away from.
                if (cross > 0) {
                    n1 = n1.times(-1);
                    n2 = n2.times(-1);
                }
                const miter = n1.add(n2).times(1 / (1 + dot));
                const length = @sqrt(miter.x * miter.x + miter.y * miter.y);
                if (length <= how.miter_limit * half) {
                    raster.piece(&.{ at, at.add(n1), at.add(miter), at.add(n2) });
                } else {
                    raster.piece(&.{ at, at.add(n1), at.add(n2) });
                }
            },
        }
    }

    /// An open end at `at`, the path leaving it going `away`.
    fn end(raster: *Raster, at: P, away: P, how: Stroke) void {
        switch (how.cap) {
            .butt => {},
            .round => raster.disc(at, how.half),
            .square => {
                const normal = P{ .x = -away.y * how.half, .y = away.x * how.half };
                const out = at.add(away.times(how.half));
                raster.piece(&.{ at.add(normal), out.add(normal), out.sub(normal), at.sub(normal) });
            },
        }
    }

    /// What was added laid onto the canvas in `colour`, at `alpha`, and
    /// the buffer cleared where it was.
    pub fn paint(raster: *Raster, canvas: Canvas, colour: Colour, alpha: f32, even_odd: bool) void {
        if (raster.top >= raster.bottom) return raster.forget();
        const stride_width = raster.stride();
        const red = colour.r * 255;
        const green = colour.g * 255;
        const blue = colour.b * 255;
        const opacity = @min(@max(alpha, 0), 1);
        var y = raster.top;
        while (y < @min(raster.bottom, raster.height)) : (y += 1) {
            const row = raster.acc + @as(usize, y) * stride_width;
            const pens = canvas.row(y);
            var sum: f32 = 0;
            var x = raster.left;
            while (x < stride_width) : (x += 1) {
                sum += row[x];
                row[x] = 0;
                if (x >= raster.width) continue;
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
        raster.forget();
    }

    fn forget(raster: *Raster) void {
        raster.top = 0xFFFF_FFFF;
        raster.bottom = 0;
        raster.left = 0xFFFF_FFFF;
    }
};

fn unit(v: P) ?P {
    const length = @sqrt(v.x * v.x + v.y * v.y);
    if (length < 1e-3) return null;
    return v.times(1 / length);
}

/// A colour at `a` laid over a pen.
fn over(pen: Pen, red: f32, green: f32, blue: f32, a: f32) Pen {
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

const testing = @import("std").testing;

fn testRaster(acc: []f32, width: u32, height: u32) Raster {
    @memset(acc, 0);
    return .{ .acc = acc.ptr, .width = width, .height = height };
}

test "a square half off the frame is filled where it is on it" {
    var acc: [10 * 8]f32 = undefined;
    var raster = testRaster(&acc, 8, 8);
    var pens: [64]Pen = @splat(0);
    raster.polygon(&.{ .{ .x = -4, .y = 2 }, .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 6 }, .{ .x = -4, .y = 6 } });
    raster.paint(.{ .pens = &pens, .bytes_per_row = 32, .width = 8, .height = 8 }, .{ .r = 1, .g = 0, .b = 0 }, 1, false);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[3 * 8 + 0]);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[5 * 8 + 3]);
    try testing.expectEqual(@as(Pen, 0), pens[3 * 8 + 4]);
    try testing.expectEqual(@as(Pen, 0), pens[1 * 8 + 0]);
    for (acc) |left| try testing.expectEqual(@as(f32, 0), left);
}

test "a hole by the even-odd rule, none by non-zero" {
    var acc: [12 * 10]f32 = undefined;
    var raster = testRaster(&acc, 10, 10);
    var pens: [100]Pen = @splat(0);
    const canvas = Canvas{ .pens = &pens, .bytes_per_row = 40, .width = 10, .height = 10 };
    const outer = [_]P{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } };
    const inner = [_]P{ .{ .x = 3, .y = 3 }, .{ .x = 7, .y = 3 }, .{ .x = 7, .y = 7 }, .{ .x = 3, .y = 7 } };
    raster.polygon(&outer);
    raster.polygon(&inner);
    raster.paint(canvas, .{ .r = 0, .g = 0, .b = 1 }, 1, true);
    try testing.expectEqual(@as(Pen, 0), pens[5 * 10 + 5]);
    try testing.expectEqual(@as(Pen, 0xFF0000FF), pens[1 * 10 + 1]);
    raster.polygon(&outer);
    raster.polygon(&inner);
    raster.paint(canvas, .{ .r = 0, .g = 1, .b = 0 }, 1, false);
    try testing.expectEqual(@as(Pen, 0xFF00FF00), pens[5 * 10 + 5]);
}

test "a stroke covers its width" {
    var acc: [22 * 20]f32 = undefined;
    var raster = testRaster(&acc, 20, 20);
    var pens: [400]Pen = @splat(0);
    var points: [16]P = undefined;
    var ends: [4]u32 = undefined;
    var closed: [4]bool = undefined;
    var outline = Outline{ .points = &points, .ends = &ends, .closed = &closed };
    outline.moveTo(.{ .x = 2, .y = 10 });
    outline.lineTo(.{ .x = 10, .y = 10 });
    outline.lineTo(.{ .x = 10, .y = 18 });
    outline.end(false);
    raster.stroke(&outline, .{ .half = 2, .join = .miter, .cap = .square });
    raster.paint(.{ .pens = &pens, .bytes_per_row = 80, .width = 20, .height = 20 }, .{ .r = 1, .g = 1, .b = 1 }, 1, false);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[9 * 20 + 5]);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[10 * 20 + 1]);
    // The miter's outer corner.
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[8 * 20 + 11]);
    try testing.expectEqual(@as(Pen, 0), pens[5 * 20 + 5]);
    try testing.expectEqual(@as(Pen, 0), pens[14 * 20 + 5]);
}
