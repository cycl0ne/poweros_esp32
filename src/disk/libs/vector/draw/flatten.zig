// SPDX-License-Identifier: MIT
//! A path broken into contours of points, when it is drawn: each curve
//! into lines enough that none strays from it by more than a quarter of a
//! pixel at the size it is drawn at - lottie.datatype's rule, moved here
//! (from its raster.zig) when vector.library 1.0 was made.
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

/// Every contour of the path, flattened onto `out` and handed to `emit`
/// with whether it is closed. False when `out` could not hold one: that
/// contour is handed over as far as it went, and the walk stops.
pub fn contours(path: *const Path, how: Flatten, out: *List(P), memory: Memory, context: anytype, comptime emit: fn (@TypeOf(context), []const P, bool) void) bool {
    const place_identity = how.place.isIdentity();
    const measure_identity = how.measure.isIdentity();
    var walk = path.walk();
    var open = false;
    out.clear();
    while (walk.next()) |segment| {
        const pts = segment.points;
        switch (segment.verb) {
            .move => {
                if (open) emit(context, out.items(), false);
                out.clear();
                open = true;
                if (!out.append(memory, placed(how, place_identity, pts[0]))) return failed(out, context, emit);
            },
            .line => {
                if (!out.append(memory, placed(how, place_identity, pts[0]))) return failed(out, context, emit);
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
                if (!cubic(out, memory, how, measure_identity, c1, c2, p3)) return failed(out, context, emit);
            },
            .cubic => {
                const c1 = placed(how, place_identity, pts[0]);
                const c2 = placed(how, place_identity, pts[1]);
                const p3 = placed(how, place_identity, pts[2]);
                if (!cubic(out, memory, how, measure_identity, c1, c2, p3)) return failed(out, context, emit);
            },
            .close => {
                if (open) emit(context, out.items(), true);
                out.clear();
                open = false;
            },
        }
    }
    if (open) emit(context, out.items(), false);
    out.clear();
    return true;
}

fn failed(out: *List(P), context: anytype, comptime emit: fn (@TypeOf(context), []const P, bool) void) bool {
    if (out.len > 0) emit(context, out.items(), false);
    out.clear();
    return false;
}

fn placed(how: Flatten, identity: bool, p: P) P {
    return if (identity) p else how.place.apply(p);
}

fn measured(how: Flatten, identity: bool, p: P) P {
    return if (identity) p else how.measure.apply(p);
}

/// A cubic curve from the last point: lines enough that none strays from
/// it by more than a quarter of a pixel.
fn cubic(out: *List(P), memory: Memory, how: Flatten, measure_identity: bool, p1: P, p2: P, p3: P) bool {
    const items = out.items();
    const p0 = items[items.len - 1];
    const m0 = measured(how, measure_identity, p0);
    const m1 = measured(how, measure_identity, p1);
    const m2 = measured(how, measure_identity, p2);
    const m3 = measured(how, measure_identity, p3);
    const d1 = add(sub(m0, times(m1, 2)), m2);
    const d2 = add(sub(m1, times(m2, 2)), m3);
    const deviation = @max(@sqrt(d1.x * d1.x + d1.y * d1.y), @sqrt(d2.x * d2.x + d2.y * d2.y));
    if (deviation < 0.1) return out.append(memory, p3);
    const steps: u32 = @min(1 + @as(u32, @intFromFloat(@sqrt(deviation * 3.0))), 64);
    if (!out.reserve(memory, steps)) return false;
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
    }
    return true;
}

// --- tests ---------------------------------------------------------------------

const testing = @import("std").testing;
const test_memory = memory_.test_memory;

const Seen = struct {
    contours: u32 = 0,
    points: u32 = 0,
    closed: u32 = 0,
    last: P = .{},

    fn emit(seen: *Seen, points: []const P, closed: bool) void {
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
    var small: Seen = .{};
    try testing.expect(contours(path, Flatten.fill(.{}), &out, test_memory, &small, Seen.emit));
    var large: Seen = .{};
    try testing.expect(contours(path, Flatten.fill(Matrix.scale(8, 8)), &out, test_memory, &large, Seen.emit));
    try testing.expectEqual(@as(u32, 1), small.closed);
    try testing.expect(large.points > small.points);
    try testing.expectEqual(P{ .x = 80, .y = 0 }, large.last);
    // A stroke's points stay in the path's units, measured in pixels.
    var stroked: Seen = .{};
    try testing.expect(contours(path, Flatten.stroke(Matrix.scale(8, 8)), &out, test_memory, &stroked, Seen.emit));
    try testing.expectEqual(large.points, stroked.points);
    try testing.expectEqual(P{ .x = 10, .y = 0 }, stroked.last);
}
