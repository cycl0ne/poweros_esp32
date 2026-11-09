// SPDX-License-Identifier: MIT
//! Coverage by signed area: lines in pixels, summed into how much of each
//! pixel the shape they bound covers. lottie.datatype's method, moved here
//! (from its raster.zig) when vector.library 1.0 was made.
//!
//! Every line adds to an accumulation buffer, for each row it crosses,
//! the share of each pixel it passes that lies to its right - positive
//! going down, negative going up. Summing a row from the left then gives
//! at each pixel the winding of the paths over it, fractional at their
//! edges: its size clamped to 1 is the coverage of the non-zero rule, its
//! distance from the nearest even number that of the even-odd rule.
//!
//! A line outside the canvas on the left adds its whole share to the
//! first column, one on the right nothing: lines are cut where they cross
//! either side and their pieces held to it.
//!
//! **A band of rows at a time.** The buffer holds the rows from
//! `band_top` up to `band_end`, and a line adds only to those. A line
//! that starts above the band is followed down to it row by row, as it
//! would be were the band the whole canvas, so a row comes out the same
//! whichever band it is drawn in.

const sdk = @import("sdk");
const P = sdk.vector.Point;

pub fn add(a: P, b: P) P {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}
pub fn sub(a: P, b: P) P {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}
pub fn times(a: P, s: f32) P {
    return .{ .x = a.x * s, .y = a.y * s };
}

/// The accumulation buffer for a band: rows of `width + 2`, so a line on
/// the right edge still has somewhere to put what lies right of it; and
/// the rows and first column touched since it was last laid down.
pub const Coverage = struct {
    acc: [*]f32,
    width: u32,
    /// The canvas's height: nothing is below it.
    height: u32,
    band_top: u32 = 0,
    band_end: u32,
    top: u32 = 0xFFFF_FFFF,
    bottom: u32 = 0,
    left: u32 = 0xFFFF_FFFF,

    pub fn stride(coverage: *const Coverage) u32 {
        return coverage.width + 2;
    }

    /// How many floats a band of `rows` rows this wide holds.
    pub fn floats(width: u32, rows: u32) usize {
        return @as(usize, width + 2) * rows;
    }

    /// Whether anything was added since the last `forget`.
    pub fn touched(coverage: *const Coverage) bool {
        return coverage.top < coverage.bottom;
    }

    pub fn forget(coverage: *Coverage) void {
        coverage.top = 0xFFFF_FFFF;
        coverage.bottom = 0;
        coverage.left = 0xFFFF_FFFF;
    }

    /// A line, cut at the canvas's sides.
    pub fn line(coverage: *Coverage, p0: P, p1: P) void {
        if (p0.y == p1.y) return;
        if (p0.y != p0.y or p1.y != p1.y or p0.x != p0.x or p1.x != p1.x) return;
        // Wholly above or below the band: nothing of it is here.
        const band_top: f32 = @floatFromInt(coverage.band_top);
        const band_end: f32 = @floatFromInt(coverage.band_end);
        if (@max(p0.y, p1.y) <= band_top or @min(p0.y, p1.y) >= band_end) return;
        const right: f32 = @floatFromInt(coverage.width);
        for ([_]f32{ 0, right }) |side| {
            if ((p0.x < side) != (p1.x < side) and p0.x != side and p1.x != side) {
                const t = (side - p0.x) / (p1.x - p0.x);
                const middle = P{ .x = side, .y = p0.y + t * (p1.y - p0.y) };
                coverage.line(p0, middle);
                coverage.line(middle, p1);
                return;
            }
        }
        coverage.inside(.{ .x = @min(@max(p0.x, 0), right), .y = p0.y }, .{ .x = @min(@max(p1.x, 0), right), .y = p1.y });
    }

    fn addAt(coverage: *Coverage, row_start: usize, x: i32, value: f32) void {
        if (x < 0 or x >= coverage.stride()) return;
        coverage.acc[row_start + @as(usize, @intCast(x))] += value;
    }

    /// A line between 0 and the width: its share of each pixel of each
    /// row of the band it crosses.
    fn inside(coverage: *Coverage, p0: P, p1: P) void {
        const dir: f32 = if (p0.y < p1.y) 1 else -1;
        const a = if (p0.y < p1.y) p0 else p1;
        const b = if (p0.y < p1.y) p1 else p0;
        const dxdy = (b.x - a.x) / (b.y - a.y);
        const rows: f32 = @floatFromInt(coverage.height);
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
        if (y_end <= coverage.band_top or y >= coverage.band_end) return;
        coverage.top = @min(coverage.top, @max(y, coverage.band_top));
        coverage.bottom = @max(coverage.bottom, @min(y_end, coverage.band_end));
        const leftmost: u32 = @intFromFloat(@floor(@max(@min(a.x, b.x), 0)));
        coverage.left = @min(coverage.left, leftmost);
        const stride_width = coverage.stride();
        while (y < y_end) : (y += 1) {
            if (y >= coverage.band_end) break;
            const yf: f32 = @floatFromInt(y);
            const dy = @min(yf + 1, y_bottom) - @max(yf, y_top);
            const x_next = x + dxdy * dy;
            defer x = x_next;
            if (y < coverage.band_top) continue;
            const row_start = @as(usize, y - coverage.band_top) * stride_width;
            const d = dy * dir;
            const x0 = @min(x, x_next);
            const x1 = @max(x, x_next);
            const x0_floor = @floor(x0);
            const x0i: i32 = @intFromFloat(x0_floor);
            const x1_ceil = @ceil(x1);
            const x1i: i32 = @intFromFloat(x1_ceil);
            if (x1i <= x0i + 1) {
                const xmf = 0.5 * (x + x_next) - x0_floor;
                coverage.addAt(row_start, x0i, d - d * xmf);
                coverage.addAt(row_start, x0i + 1, d * xmf);
            } else {
                const s = 1 / (x1 - x0);
                const x0f = x0 - x0_floor;
                const a0 = 0.5 * s * (1 - x0f) * (1 - x0f);
                const x1f = x1 - x1_ceil + 1;
                const am = 0.5 * s * x1f * x1f;
                coverage.addAt(row_start, x0i, d * a0);
                if (x1i == x0i + 2) {
                    coverage.addAt(row_start, x0i + 1, d * (1 - a0 - am));
                } else {
                    const a1 = s * (1.5 - x0f);
                    coverage.addAt(row_start, x0i + 1, d * (a1 - a0));
                    var xi = x0i + 2;
                    while (xi < x1i - 1) : (xi += 1) coverage.addAt(row_start, xi, d * s);
                    const a2 = a1 + @as(f32, @floatFromInt(x1i - x0i - 3)) * s;
                    coverage.addAt(row_start, x1i - 1, d * (1 - a2 - am));
                }
                coverage.addAt(row_start, x1i, d * am);
            }
        }
    }

    /// A closed polygon, as it is wound.
    pub fn polygon(coverage: *Coverage, points: []const P) void {
        if (points.len < 2) return;
        var previous = points[points.len - 1];
        for (points) |p| {
            coverage.line(previous, p);
            previous = p;
        }
    }

    /// A convex polygon, wound the one way every piece of a stroke is.
    pub fn piece(coverage: *Coverage, points: []const P) void {
        var twice_area: f32 = 0;
        var previous = points[points.len - 1];
        for (points) |p| {
            twice_area += previous.x * p.y - p.x * previous.y;
            previous = p;
        }
        if (twice_area >= 0) return coverage.polygon(points);
        var i = points.len;
        previous = points[0];
        while (i > 0) {
            i -= 1;
            coverage.line(previous, points[i]);
            previous = points[i];
        }
    }

    /// Row `y`'s floats: the band's, so `y` is in it.
    pub fn row(coverage: *const Coverage, y: u32) [*]f32 {
        return coverage.acc + @as(usize, y - coverage.band_top) * coverage.stride();
    }
};

// --- tests ---------------------------------------------------------------------

const testing = @import("std").testing;

fn summed(coverage: *Coverage, y: u32, x: u32) f32 {
    const r = coverage.row(y);
    var sum: f32 = 0;
    for (0..x + 1) |i| sum += r[i];
    return sum;
}

test "a square half off the canvas covers its pixels on it, whole" {
    var acc: [10 * 8]f32 = @splat(0);
    var coverage = Coverage{ .acc = &acc, .width = 8, .height = 8, .band_end = 8 };
    coverage.polygon(&.{ .{ .x = -4, .y = 2 }, .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 6 }, .{ .x = -4, .y = 6 } });
    try testing.expectEqual(@as(f32, 1), @abs(summed(&coverage, 3, 0)));
    try testing.expectEqual(@as(f32, 1), @abs(summed(&coverage, 5, 3)));
    try testing.expectEqual(@as(f32, 0), summed(&coverage, 3, 4));
    try testing.expectEqual(@as(f32, 0), summed(&coverage, 1, 0));
}

test "a band adds the same to its rows as the whole canvas does" {
    const shape = [_]P{ .{ .x = 1.3, .y = 0.7 }, .{ .x = 7.6, .y = 2.2 }, .{ .x = 5.1, .y = 9.4 }, .{ .x = 0.2, .y = 6.9 } };
    var whole_acc: [10 * 10]f32 = @splat(0);
    var whole = Coverage{ .acc = &whole_acc, .width = 8, .height = 10, .band_end = 10 };
    whole.polygon(&shape);
    var band_acc: [10 * 3]f32 = @splat(0);
    var band = Coverage{ .acc = &band_acc, .width = 8, .height = 10, .band_top = 4, .band_end = 7 };
    band.polygon(&shape);
    try testing.expectEqual(@as(u32, 4), band.top);
    try testing.expectEqual(@as(u32, 7), band.bottom);
    for (4..7) |y| {
        const a = whole.row(@intCast(y));
        const b = band.row(@intCast(y));
        for (0..10) |x| try testing.expectEqual(a[x], b[x]);
    }
}
