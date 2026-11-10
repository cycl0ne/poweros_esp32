// SPDX-License-Identifier: MIT
//! A path broken into contours of points, when it is drawn: each curve
//! into lines enough that none strays from it by more than a tenth of a
//! pixel at the size it is drawn at - cairo's tolerance, and so what
//! SVG's pictures are drawn to. Until 1.2 a quarter, lottie.datatype's
//! rule, moved here (from its raster.zig) when vector.library 1.0 was
//! made: a thin stroke's edge on the inside of a curve came out heavy.
//!
//! Beside every point goes whether it is inside a curve rather than where
//! the path's own segments meet (`smooth`): a stroke turns round there,
//! whatever its join, as the curve itself does, so a curve that doubles
//! back on itself does not grow a miter's spike.
//!
//! The points are put down through `place` and measured through
//! `measure` after it. A fill puts them down in pixels (`place` the
//! matrix it is drawn through) and measures them as they are; a stroke
//! puts them down in the path's own units and measures them in pixels,
//! so its pieces are made in the units the path was built in.

const sdk = @import("sdk");
const vector = sdk.vector;
const P = vector.Point;
const Matrix = vector.Matrix;
const memory_ = @import("memory.zig");
const Memory = memory_.Memory;
const List = memory_.List;
const path_ = @import("path.zig");
const Path = path_.Path;
const coverage_ = @import("coverage.zig");
const add = coverage_.add;
const sub = coverage_.sub;
const times = coverage_.times;

pub const Flatten = struct {
    place: Matrix = .{},
    measure: Matrix = .{},

    /// A fill's: the points in pixels.
    pub fn fill(matrix: Matrix) Flatten {
        return .{ .place = matrix };
    }

    /// A stroke's: the points in the path's units, measured in pixels.
    pub fn stroke(matrix: Matrix) Flatten {
        return .{ .measure = matrix };
    }
};

/// What a contour is handed to: its points, whether each is inside a
/// curve, and whether it is closed.
pub fn Emit(comptime Context: type) type {
    return fn (Context, []const P, []const bool, bool) void;
}

/// Every contour of the path, flattened onto `out` - its points'
/// smoothness onto `smooth` - and handed to `emit` with whether it is
/// closed. False when the lists could not hold one: that contour is
/// handed over as far as it went, and the walk stops.
pub fn contours(path: *const Path, how: Flatten, out: *List(P), smooth: *List(bool), memory: Memory, context: anytype, comptime emit: Emit(@TypeOf(context))) bool {
    const place_identity = how.place.isIdentity();
    const measure_identity = how.measure.isIdentity();
    var walk = path.walk();
    var open = false;
    out.clear();
    smooth.clear();
    while (walk.next()) |segment| {
        const pts = segment.points;
        switch (segment.verb) {
            .move => {
                if (open) emit(context, out.items(), smooth.items(), false);
                out.clear();
                smooth.clear();
                open = true;
                if (!point(out, smooth, memory, placed(how, place_identity, pts[0]), false)) return failed(out, smooth, context, emit);
            },
            .line => {
                if (!point(out, smooth, memory, placed(how, place_identity, pts[0]), false)) return failed(out, smooth, context, emit);
            },
            .quad => {
                const items = out.items();
                const p0 = items[items.len - 1];
                const q = placed(how, place_identity, pts[0]);
                const p3 = placed(how, place_identity, pts[1]);
                // The same curve as a cubic one: its control points two
                // thirds of the way from each end to the quadratic's.
                const c1 = add(p0, times(sub(q, p0), 2.0 / 3.0));
                const c2 = add(p3, times(sub(q, p3), 2.0 / 3.0));
                if (!cubic(out, smooth, memory, how, measure_identity, c1, c2, p3)) return failed(out, smooth, context, emit);
            },
            .cubic => {
                const c1 = placed(how, place_identity, pts[0]);
                const c2 = placed(how, place_identity, pts[1]);
                const p3 = placed(how, place_identity, pts[2]);
                if (!cubic(out, smooth, memory, how, measure_identity, c1, c2, p3)) return failed(out, smooth, context, emit);
            },
            .close => {
                if (open) emit(context, out.items(), smooth.items(), true);
                out.clear();
                smooth.clear();
                open = false;
            },
        }
    }
    if (open) emit(context, out.items(), smooth.items(), false);
    out.clear();
    smooth.clear();
    return true;
}

fn failed(out: *List(P), smooth: *List(bool), context: anytype, comptime emit: Emit(@TypeOf(context))) bool {
    if (out.len > 0) emit(context, out.items(), smooth.items(), false);
    out.clear();
    smooth.clear();
    return false;
}

/// A point and its smoothness, both or neither.
fn point(out: *List(P), smooth: *List(bool), memory: Memory, p: P, inside: bool) bool {
    if (!out.reserve(memory, 1) or !smooth.reserve(memory, 1)) return false;
    _ = out.append(memory, p);
    _ = smooth.append(memory, inside);
    return true;
}

fn placed(how: Flatten, identity: bool, p: P) P {
    return if (identity) p else how.place.apply(p);
}

fn measured(how: Flatten, identity: bool, p: P) P {
    return if (identity) p else how.measure.apply(p);
}

/// A cubic curve from the last point: lines enough that none strays from
/// it by more than a tenth of a pixel. n lines stray at most 3/4 D / n²,
/// D the larger of its second differences.
fn cubic(out: *List(P), smooth: *List(bool), memory: Memory, how: Flatten, measure_identity: bool, p1: P, p2: P, p3: P) bool {
    const items = out.items();
    const p0 = items[items.len - 1];
    const m0 = measured(how, measure_identity, p0);
    const m1 = measured(how, measure_identity, p1);
    const m2 = measured(how, measure_identity, p2);
    const m3 = measured(how, measure_identity, p3);
    const d1 = add(sub(m0, times(m1, 2)), m2);
    const d2 = add(sub(m1, times(m2, 2)), m3);
    const deviation = @max(@sqrt(d1.x * d1.x + d1.y * d1.y), @sqrt(d2.x * d2.x + d2.y * d2.y));
    if (deviation < 0.1) return point(out, smooth, memory, p3, false);
    const steps: u32 = @min(1 + @as(u32, @intFromFloat(@sqrt(deviation * 7.5))), 64);
    if (!out.reserve(memory, steps) or !smooth.reserve(memory, steps)) return false;
    var i: u32 = 1;
    while (i <= steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const u = 1 - t;
        const a = u * u * u;
        const b = 3 * u * u * t;
        const c = 3 * u * t * t;
        const d = t * t * t;
        _ = out.append(memory, .{
            .x = a * p0.x + b * p1.x + c * p2.x + d * p3.x,
            .y = a * p0.y + b * p1.y + c * p2.y + d * p3.y,
        });
        // Its end is where the path's segments meet; the rest are inside.
        _ = smooth.append(memory, i < steps);
    }
    return true;
}

// --- tests ---------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;
const test_memory = memory_.test_memory;

const Seen = struct {
    contours: u32 = 0,
    points: u32 = 0,
    closed: u32 = 0,
    smooth: u32 = 0,
    last: P = .{},

    fn emit(seen: *Seen, points: []const P, smooth: []const bool, closed: bool) void {
        seen.smooth += @intCast(std.mem.count(bool, smooth, &.{true}));
        seen.contours += 1;
        seen.points += @intCast(points.len);
        if (closed) seen.closed += 1;
        seen.last = points[points.len - 1];
    }
};

test "a curve drawn larger is broken into more lines, and ends where it ends" {
    const path = Path.create(test_memory).?;
    defer path.destroy();
    path.moveTo(.{ .x = 0, .y = 0 });
    path.cubicTo(.{ .x = 0, .y = 10 }, .{ .x = 10, .y = 10 }, .{ .x = 10, .y = 0 });
    path.close();
    var out: List(P) = .{};
    defer out.deinit(test_memory);
    var smooth: List(bool) = .{};
    defer smooth.deinit(test_memory);
    var small: Seen = .{};
    try testing.expect(contours(path, Flatten.fill(.{}), &out, &smooth, test_memory, &small, Seen.emit));
    var large: Seen = .{};
    try testing.expect(contours(path, Flatten.fill(Matrix.scale(8, 8)), &out, &smooth, test_memory, &large, Seen.emit));
    try testing.expectEqual(@as(u32, 1), small.closed);
    try testing.expect(large.points > small.points);
    try testing.expectEqual(P{ .x = 80, .y = 0 }, large.last);
    // Every point inside the curve, not the move or its end.
    try testing.expectEqual(large.points - 2, large.smooth);
    // A stroke's points stay in the path's units, measured in pixels.
    var stroked: Seen = .{};
    try testing.expect(contours(path, Flatten.stroke(Matrix.scale(8, 8)), &out, &smooth, test_memory, &stroked, Seen.emit));
    try testing.expectEqual(large.points, stroked.points);
    try testing.expectEqual(P{ .x = 10, .y = 0 }, stroked.last);
}
