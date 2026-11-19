// SPDX-License-Identifier: MIT
//! Paint's shapes: rectangles, ellipses, curves and polygons, drawn into
//! the picture with the brush as outlines or filled in the colour - laid
//! with the ink either way (brush.zig), so at its opacity.
//!
//! An outline is the brush stamped along it (brush.zig), so a shape's line
//! is as wide and as round as the brush; a filled shape takes no brush and
//! covers its outline's one-pixel path too, so it meets an outline drawn
//! round it without a gap.
//!
//! A rectangle and an ellipse are given by two opposite corners of their
//! box, both inside it. The ellipse is the pixels whose middles lie in it,
//! worked out a row at a time in whole numbers from twice the distances
//! (so a box of an even size, whose middle falls between pixels, is
//! exact); its outline is the pixels of each row that lie at its ends or
//! have no neighbour above or below in the shape. A curve runs from its
//! first point to its last and passes through the third, its bend, half
//! way along: a quadratic curve, drawn as short lines. A polygon is
//! filled by its pixels' middles, a row at a time, with the even-odd
//! rule: a part enclosed twice by a crossing outline stays open.
//!
//! The frame round what is being cut as a brush is a one-pixel outline
//! of dashes, four pixels black and four white, which shows on any
//! colour.

const picture_zig = @import("picture.zig");
const brush_zig = @import("brush.zig");
const Picture = picture_zig.Picture;
const Pixel = picture_zig.Pixel;
const Area = picture_zig.Area;
const Brush = brush_zig.Brush;
const Ink = brush_zig.Ink;

pub const Point = [2]i32;

/// The most corners a polygon has.
pub const max_points = 128;

/// The box two corners make, both in it.
const Box = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    fn of(a: Point, b: Point) Box {
        return .{ .x0 = @min(a[0], b[0]), .y0 = @min(a[1], b[1]), .x1 = @max(a[0], b[0]), .y1 = @max(a[1], b[1]) };
    }
};

/// The area two corners make, both in it.
pub fn areaOf(a: Point, b: Point) Area {
    const box = Box.of(a, b);
    return .{ .min_x = box.x0, .min_y = box.y0, .max_x = box.x1 + 1, .max_y = box.y1 + 1 };
}

/// The frame of the box two corners make, both in it, in dashes of black
/// and white, cut to the picture.
pub fn frame(picture: *Picture, a: Point, b: Point, changed: *Area) void {
    const box = Box.of(a, b);
    const right: i32 = @as(i32, @intCast(picture.width)) - 1;
    const bottom: i32 = @as(i32, @intCast(picture.height)) - 1;
    var x = @max(box.x0, 0);
    while (x <= @min(box.x1, right)) : (x += 1) {
        dash(picture, x, box.y0, changed);
        dash(picture, x, box.y1, changed);
    }
    var y = @max(box.y0, 0);
    while (y <= @min(box.y1, bottom)) : (y += 1) {
        dash(picture, box.x0, y, changed);
        dash(picture, box.x1, y, changed);
    }
}

/// The line from `a` to `b`, both in, in dashes of black and white, cut
/// to the picture: a drag shown, not painted.
pub fn guide(picture: *Picture, a: Point, b: Point, changed: *Area) void {
    const dx: i32 = @intCast(@abs(b[0] - a[0]));
    const dy: i32 = -@as(i32, @intCast(@abs(b[1] - a[1])));
    const step_x: i32 = if (a[0] < b[0]) 1 else -1;
    const step_y: i32 = if (a[1] < b[1]) 1 else -1;
    var x = a[0];
    var y = a[1];
    var left = dx + dy;
    while (true) {
        dash(picture, x, y, changed);
        if (x == b[0] and y == b[1]) break;
        const twice = 2 * left;
        if (twice >= dy) {
            left += dy;
            x += step_x;
        }
        if (twice <= dx) {
            left += dx;
            y += step_y;
        }
    }
}

fn dash(picture: *Picture, x: i32, y: i32, changed: *Area) void {
    if (!picture.inside(x, y)) return;
    picture.set(@intCast(x), @intCast(y), if ((x + y) & 4 == 0) 0xFF000000 else 0xFFFFFFFF);
    changed.* = changed.add(.{ .min_x = x, .min_y = y, .max_x = x + 1, .max_y = y + 1 });
}

/// The row `y` from `x0` to `x1`, both in, laid with the ink, cut to
/// the picture.
fn span(ink: *Ink, y: i32, x0: i32, x1: i32, changed: *Area) void {
    const picture = ink.picture;
    const cut = (Area{ .min_x = x0, .min_y = y, .max_x = x1 + 1, .max_y = y + 1 }).clip(picture.width, picture.height);
    if (cut.isEmpty()) return;
    if (ink.settings.whole() and ink.kind == .paint) {
        @memset(picture.row(@intCast(y))[@intCast(cut.min_x)..@intCast(cut.max_x)], ink.colour);
    } else {
        var x = cut.min_x;
        while (x < cut.max_x) : (x += 1) ink.put(@intCast(x), @intCast(y), .{ .colour = ink.colour, .coverage = 255 });
    }
    changed.* = changed.add(cut);
}

pub fn rectangle(ink: *Ink, brush: Brush, a: Point, b: Point, filled: bool, changed: *Area) void {
    const box = Box.of(a, b);
    if (filled) {
        var y = @max(box.y0, 0);
        while (y <= @min(box.y1, @as(i32, @intCast(ink.picture.height)) - 1)) : (y += 1) span(ink, y, box.x0, box.x1, changed);
        return;
    }
    brush_zig.line(ink, brush, box.x0, box.y0, box.x1, box.y0, changed);
    brush_zig.line(ink, brush, box.x1, box.y0, box.x1, box.y1, changed);
    brush_zig.line(ink, brush, box.x1, box.y1, box.x0, box.y1, changed);
    brush_zig.line(ink, brush, box.x0, box.y1, box.x0, box.y0, changed);
}

/// The largest whole number whose square is at most `n`.
fn squareRoot(n: u128) u128 {
    if (n < 2) return n;
    var low: u128 = 1;
    var high: u128 = @min(n, 1 << 64);
    while (low < high) {
        const middle = low + (high - low + 1) / 2;
        if (middle * middle <= n) low = middle else high = middle - 1;
    }
    return low;
}

/// The ellipse's pixels in the row `y`: its first and last, or null for
/// a row outside it.
fn ellipseRow(box: Box, y: i32) ?[2]i32 {
    if (y < box.y0 or y > box.y1) return null;
    // Twice the radii, and twice the row's distance from the middle.
    const across: i128 = box.x1 - box.x0;
    const down: i128 = box.y1 - box.y0;
    const from_middle: i128 = 2 * @as(i128, y) - box.y0 - box.y1;
    var half: i128 = across;
    if (down != 0) {
        // The largest twice-distance across with
        // half² · down² + from_middle² · across² <= across² · down².
        const room = across * across * (down * down - from_middle * from_middle);
        if (room < 0) return null;
        half = @intCast(squareRoot(@intCast(@divFloor(room, down * down))));
        // A pixel's twice-distance has the parity of the box's width.
        if (@mod(half - across, 2) != 0) half -= 1;
        if (half < 0) return null;
    }
    const middle2: i128 = @as(i128, box.x0) + box.x1;
    return .{ @intCast(@divExact(middle2 - half, 2)), @intCast(@divExact(middle2 + half, 2)) };
}

pub fn ellipse(ink: *Ink, brush: Brush, a: Point, b: Point, filled: bool, changed: *Area) void {
    const box = Box.of(a, b);
    // Rows beyond the brush's reach above and below the picture change
    // nothing.
    const reach: i32 = @intCast(brush.span());
    const first = @max(box.y0, -reach);
    const last = @min(box.y1, @as(i32, @intCast(ink.picture.height)) + reach);
    var y = first;
    while (y <= last) : (y += 1) {
        const row = ellipseRow(box, y) orelse continue;
        if (filled) {
            span(ink, y, row[0], row[1], changed);
            continue;
        }
        // The pixels with a neighbour above and below, and not at an end,
        // are inside: the rest of the row is the outline.
        var inner_from = row[0] + 1;
        var inner_to = row[1] - 1;
        for ([_]i32{ y - 1, y + 1 }) |near| {
            if (ellipseRow(box, near)) |other| {
                inner_from = @max(inner_from, other[0]);
                inner_to = @min(inner_to, other[1]);
            } else {
                inner_from = row[1] + 1;
            }
        }
        var x = row[0];
        while (x <= row[1]) : (x += 1) {
            if (x >= inner_from and x <= inner_to) {
                x = inner_to;
                continue;
            }
            brush_zig.stamp(ink, brush, x, y, changed);
        }
    }
}

/// From `from` to `to` through `through`, half way along.
pub fn curve(ink: *Ink, brush: Brush, from: Point, to: Point, through: Point, changed: *Area) void {
    // Twice the control point: the curve's middle is a quarter of each
    // end and half of the control point.
    const control2 = [2]i64{ 4 * @as(i64, through[0]) - from[0] - to[0], 4 * @as(i64, through[1]) - from[1] - to[1] };
    const length = distance(from, through) + distance(through, to);
    const steps: i64 = @max(8, @min(256, @divTrunc(length, 4)));
    const whole = 2 * steps * steps;
    var last = from;
    var step: i64 = 1;
    while (step <= steps) : (step += 1) {
        const rest = steps - step;
        var at: Point = undefined;
        for (0..2) |axis| {
            const sum = 2 * rest * rest * from[axis] + 2 * rest * step * control2[axis] + 2 * step * step * to[axis];
            at[axis] = @intCast(@divFloor(sum + @divTrunc(whole, 2), whole));
        }
        brush_zig.line(ink, brush, last[0], last[1], at[0], at[1], changed);
        last = at;
    }
    brush_zig.finish(ink, brush, to[0], to[1], changed);
}

fn distance(a: Point, b: Point) i64 {
    const across = @as(i64, a[0]) - b[0];
    const down = @as(i64, a[1]) - b[1];
    return (if (across < 0) -across else across) + (if (down < 0) -down else down);
}

/// The polygon through `points`, closed from the last back to the first.
pub fn polygon(ink: *Ink, brush: Brush, points: []const Point, filled: bool, changed: *Area) void {
    if (points.len == 0) return;
    if (filled) {
        fillPolygon(ink, points, changed);
        // Its one-pixel outline too, which the middles may leave out.
        const thin = Brush{ .size = 1 };
        outline(ink, thin, points, changed);
        return;
    }
    outline(ink, brush, points, changed);
}

fn outline(ink: *Ink, brush: Brush, points: []const Point, changed: *Area) void {
    if (points.len == 1) {
        brush_zig.stamp(ink, brush, points[0][0], points[0][1], changed);
        return;
    }
    for (points, 0..) |point, place| {
        const next = points[(place + 1) % points.len];
        brush_zig.line(ink, brush, point[0], point[1], next[0], next[1], changed);
    }
}

/// The corners' lines from `from` to the last, open: a polygon being
/// drawn.
pub fn polyline(ink: *Ink, brush: Brush, points: []const Point, changed: *Area) void {
    if (points.len == 0) return;
    brush_zig.stamp(ink, brush, points[0][0], points[0][1], changed);
    for (points[1..], 0..) |point, place| {
        const before = points[place];
        brush_zig.line(ink, brush, before[0], before[1], point[0], point[1], changed);
    }
    const end = points[points.len - 1];
    brush_zig.finish(ink, brush, end[0], end[1], changed);
}

fn fillPolygon(ink: *Ink, points: []const Point, changed: *Area) void {
    var crossings: [max_points]i64 = undefined;
    const Spans = struct {
        ink: *Ink,
        changed: *Area,

        fn put(spans: @This(), y: i32, from: i32, to: i32) void {
            span(spans.ink, y, from, to, spans.changed);
        }
    };
    polygonSpans(points, ink.picture.height, &crossings, Spans{ .ink = ink, .changed = changed }, Spans.put);
}

/// The polygon through `points`, closed, a row at a time from the top:
/// `put` is given each run of pixels whose middles it holds, by the
/// even-odd rule - its row and its first and last pixel across, the last
/// in - for the rows 0 to before `height`. A row has at most
/// `crossings.len` edges crossing it counted; past that its last ones are
/// left out.
pub fn polygonSpans(points: []const Point, height: u32, crossings: []i64, context: anytype, comptime put: fn (@TypeOf(context), i32, i32, i32) void) void {
    if (points.len == 0) return;
    var top: i32 = points[0][1];
    var bottom: i32 = points[0][1];
    for (points) |point| {
        top = @min(top, point[1]);
        bottom = @max(bottom, point[1]);
    }
    top = @max(top, 0);
    bottom = @min(bottom, @as(i32, @intCast(height)) - 1);
    // Where the edges cross a row's middle, in 256ths of twice a pixel.
    var y = top;
    while (y <= bottom) : (y += 1) {
        const middle: i64 = 2 * @as(i64, y) + 1;
        var count: usize = 0;
        for (points, 0..) |a, place| {
            const b = points[(place + 1) % points.len];
            const ay: i64 = 2 * @as(i64, a[1]) + 1;
            const by: i64 = 2 * @as(i64, b[1]) + 1;
            // Half-open, so a corner between two edges is crossed once.
            if ((ay <= middle and middle < by) or (by <= middle and middle < ay)) {
                const ax: i64 = 2 * @as(i64, a[0]) + 1;
                const bx: i64 = 2 * @as(i64, b[0]) + 1;
                if (count == crossings.len) break;
                crossings[count] = ax * 256 + @divFloor((middle - ay) * (bx - ax) * 256, by - ay);
                count += 1;
            }
        }
        // In order across, a few at a time.
        var sorted: usize = 1;
        while (sorted < count) : (sorted += 1) {
            const crossing = crossings[sorted];
            var at = sorted;
            while (at > 0 and crossings[at - 1] > crossing) : (at -= 1) crossings[at] = crossings[at - 1];
            crossings[at] = crossing;
        }
        // A pixel is in when its middle, 2x + 1, is from one crossing to
        // before the next.
        var pair: usize = 0;
        while (pair + 1 < count) : (pair += 2) {
            const from: i32 = @intCast(@divFloor(crossings[pair] - 256 + 511, 512));
            const to: i32 = @intCast(@divFloor(crossings[pair + 1] - 256 + 511, 512));
            if (to > from) put(context, y, from, to - 1);
        }
    }
}
