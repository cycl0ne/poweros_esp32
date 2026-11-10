// SPDX-License-Identifier: MIT
//! A stroke as pieces, every one wound the same way: a polygon a segment,
//! the outer side's wedge at each corner (bevel, miter or round), and at
//! an open contour's ends a square or half a disc. lottie.datatype's
//! stroker, moved here (from its raster.zig) when vector.library 1.0 was
//! made.
//!
//! **The pieces tile the stroke.** Coverage is summed signed area, so
//! where two pieces overlap in a pixel at the stroke's edge the pixel is
//! counted twice and comes out too dark. Since 1.2 a segment's inner side
//! is therefore cut back, at a corner, to where its neighbour's begins -
//! the two inner edges' crossing - and the corner's own piece is only the
//! wedge on the outer side, between the segments' square ends. Where a
//! segment is too short for that (a curve tighter than the stroke is
//! wide, a sharp corner between short lines, a curve that doubles back)
//! the ends stay square and the two overlap, as before 1.2.
//!
//! Where a curve was broken into lines, the lines meet in a round join
//! whatever the stroke's, as the curve itself turns; the stroke's own
//! join is for where the path's segments meet. Also since 1.2, so that a
//! curve that doubles back does not grow a miter's spike.
//!
//! The pieces are made in the path's own units and handed to a `Sink`,
//! which takes them to pixels: a stroke drawn through a matrix that
//! stretches one way comes out stretched, as SVG draws it.

const std = @import("std");
const sdk = @import("sdk");
const vector = sdk.vector;
const P = vector.Point;
const coverage_ = @import("coverage.zig");
const add = coverage_.add;
const sub = coverage_.sub;
const times = coverage_.times;

pub const Join = enum { miter, round, bevel };
pub const Cap = enum { butt, round, square };

pub const How = struct {
    /// Half the width, in the path's units.
    half: f32,
    join: Join = .miter,
    cap: Cap = .butt,
    /// The longest miter, in half widths.
    miter_limit: f32 = 4,

    pub fn of(stroke: *const vector.Stroke) How {
        return .{
            .half = stroke.width / 2,
            .join = switch (stroke.join) {
                vector.JOIN_ROUND => .round,
                vector.JOIN_BEVEL => .bevel,
                else => .miter,
            },
            .cap = switch (stroke.cap) {
                vector.CAP_ROUND => .round,
                vector.CAP_SQUARE => .square,
                else => .butt,
            },
            .miter_limit = stroke.miter_limit,
        };
    }
};

/// Where the pieces go: taken to pixels and added to the coverage.
pub const Sink = struct {
    coverage: *coverage_.Coverage,
    matrix: vector.Matrix,
    /// The matrix is the identity: the pieces are pixels already.
    identity: bool,
    /// How much the matrix scales a length: how many sides a disc needs.
    scale: f32,

    pub fn of(coverage: *coverage_.Coverage, matrix: vector.Matrix) Sink {
        return .{ .coverage = coverage, .matrix = matrix, .identity = matrix.isIdentity(), .scale = matrix.size() };
    }

    fn piece(sink: *Sink, points: []const P) void {
        if (sink.identity) return sink.coverage.piece(points);
        var moved: [64]P = undefined;
        for (points, 0..) |p, i| moved[i] = sink.matrix.apply(p);
        sink.coverage.piece(moved[0..points.len]);
    }

    /// How many sides a disc of `radius` has: more the larger it is drawn.
    fn sides(sink: *const Sink, radius: f32) u32 {
        const wanted: u32 = @intFromFloat(@min(@ceil(radius * sink.scale * 2), 64));
        return @min(@max(wanted, 8), 64);
    }

    fn disc(sink: *Sink, centre: P, radius: f32) void {
        if (radius * sink.scale <= 0.05) return;
        const n = sink.sides(radius);
        var points: [64]P = undefined;
        for (0..n) |i| {
            const angle = @as(f32, @floatFromInt(i)) * (2 * std.math.pi) / @as(f32, @floatFromInt(n));
            points[i] = .{ .x = centre.x + radius * @cos(angle), .y = centre.y + radius * @sin(angle) };
        }
        sink.piece(points[0..n]);
    }

    /// The slice of a disc round `centre` from `centre + from` to
    /// `centre + to`, turning `angle` (its sign the way it turns): its
    /// ends exactly those two points, so that the pieces beside it meet
    /// it edge to edge.
    fn fan(sink: *Sink, centre: P, from: P, to: P, angle: f32, radius: f32) void {
        var points: [40]P = undefined;
        points[0] = centre;
        points[1] = add(centre, from);
        var k: usize = 2;
        if (radius * sink.scale > 0.05) {
            const step = 2 * std.math.pi / @as(f32, @floatFromInt(sink.sides(radius)));
            const m: u32 = @intFromFloat(@min(@ceil(@abs(angle) / step), 32));
            var i: u32 = 1;
            while (i < m) : (i += 1) {
                const t = angle * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(m));
                const c = @cos(t);
                const s = @sin(t);
                points[k] = .{ .x = centre.x + from.x * c - from.y * s, .y = centre.y + from.x * s + from.y * c };
                k += 1;
            }
        }
        points[k] = add(centre, to);
        sink.piece(points[0 .. k + 1]);
    }
};

/// A segment's end at a corner: square across, or cut back on its inner
/// side to where the next one's inner edge crosses it.
const Cut = struct {
    /// The side cut: 1 the left normal's (`normal`), -1 the other's, 0
    /// none.
    side: f32 = 0,
    at: P = .{ .x = 0, .y = 0 },
    /// How much of each segment the corner takes, from its end.
    need: f32 = 0,
};

/// A segment between two points that are apart, and how its start was
/// cut.
const Segment = struct {
    from: P,
    to: P,
    along: P,
    length: f32,
    start: Cut = .{},

    fn of(from: P, to: P) ?Segment {
        const d = sub(to, from);
        const length = @sqrt(d.x * d.x + d.y * d.y);
        if (length < 1e-3) return null;
        return .{ .from = from, .to = to, .along = times(d, 1 / length), .length = length };
    }
};

/// A contour's points, those on the one before passed over: a point
/// they fall on is inside a curve only if they all are.
const Walk = struct {
    all: []const P,
    smooth: []const bool,
    at: usize = 0,

    const Vertex = struct { p: P, smooth: bool };

    fn next(walk: *Walk) ?Vertex {
        if (walk.at >= walk.all.len) return null;
        var v = Vertex{ .p = walk.all[walk.at], .smooth = walk.smooth[walk.at] };
        walk.at += 1;
        while (walk.at < walk.all.len and Segment.of(v.p, walk.all[walk.at]) == null) : (walk.at += 1) {
            if (!walk.smooth[walk.at]) v.smooth = false;
        }
        return v;
    }
};

/// A flattened contour stroked; `smooth` says of each point whether it
/// is inside a curve.
pub fn contour(sink: *Sink, all: []const P, smooth: []const bool, closed: bool, how: How) void {
    var walk = Walk{ .all = all, .smooth = smooth };
    const start = walk.next() orelse return;
    var end = walk.next() orelse {
        if (how.cap == .round) sink.disc(start.p, how.half);
        return;
    };
    var current = Segment.of(start.p, end.p).?;
    const head_along = current.along;
    // A closed contour's first segment waits for the corner that closes
    // it, which cuts its start.
    var head: ?Segment = null;
    var head_end: Cut = .{};
    while (walk.next()) |v| {
        var next = Segment.of(end.p, v.p).?;
        next.start = corner(sink, current, next, .{}, joinAt(how, end.smooth));
        if (closed and head == null) {
            head = current;
            head_end = next.start;
        } else segment(sink, current, next.start, how.half);
        current = next;
        end = v;
    }
    if (!closed) {
        segment(sink, current, .{}, how.half);
        cap(sink, start.p, head_along, -1, how);
        cap(sink, end.p, current.along, 1, how);
        return;
    }
    if (Segment.of(end.p, start.p)) |closing_| {
        var closing = closing_;
        closing.start = corner(sink, current, closing, .{}, joinAt(how, end.smooth));
        if (head == null) {
            head = current;
            head_end = closing.start;
        } else segment(sink, current, closing.start, how.half);
        current = closing;
        end = .{ .p = start.p, .smooth = start.smooth };
    } else {
        // The last point is the first: one corner there, made of both,
        // and the segment ending on the first exactly.
        current.to = start.p;
        end.smooth = end.smooth and start.smooth;
    }
    var first = head.?;
    first.start = corner(sink, current, first, head_end, joinAt(how, end.smooth));
    segment(sink, current, first.start, how.half);
    segment(sink, first, head_end, how.half);
}

/// The stroke's own join where segments meet, a round one inside a
/// curve.
fn joinAt(how: How, inside: bool) How {
    if (!inside) return how;
    var round = how;
    round.join = .round;
    return round;
}

/// The left normal, half the width long.
fn normal(along: P, half: f32) P {
    return .{ .x = -along.y * half, .y = along.x * half };
}

/// A segment's piece: square at both ends, or cut back on one side where
/// a corner's `Cut` says - then through its end point, which the corner's
/// wedge and the next segment's piece meet it at.
fn segment(sink: *Sink, s: Segment, end_cut: Cut, half: f32) void {
    const n = normal(s.along, half);
    var points: [6]P = undefined;
    var k: usize = 0;
    if (s.start.side > 0) {
        points[k] = s.start.at;
        k += 1;
    } else {
        points[k] = add(s.from, n);
        k += 1;
    }
    if (end_cut.side > 0) {
        points[k] = end_cut.at;
        points[k + 1] = s.to;
        k += 2;
    } else {
        points[k] = add(s.to, n);
        k += 1;
    }
    if (end_cut.side < 0) {
        points[k] = s.to;
        points[k + 1] = end_cut.at;
        k += 2;
    } else {
        points[k] = sub(s.to, n);
        k += 1;
    }
    if (s.start.side < 0) {
        points[k] = s.start.at;
        points[k + 1] = s.from;
        k += 2;
    } else {
        points[k] = sub(s.from, n);
        k += 1;
        if (s.start.side > 0) {
            points[k] = s.from;
            k += 1;
        }
    }
    sink.piece(points[0..k]);
}

/// The corner where `in` ends and `out` begins: its wedge on the outer
/// side drawn, and where the two are cut on the inner one. `far` is how
/// `out` was cut at its other end, if it was already.
fn corner(sink: *Sink, in: Segment, out: Segment, far: Cut, how: How) Cut {
    const at = in.to;
    const a = in.along;
    const b = out.along;
    const dot = a.x * b.x + a.y * b.y;
    const cross = a.x * b.y - a.y * b.x;
    const half = how.half;
    const na = normal(a, half);
    const nb = normal(b, half);
    if (@abs(cross) < 1e-6) {
        // Straight on, nothing between; doubling back, a round join's
        // half disc beyond the turn.
        if (dot < 0 and how.join == .round) sink.fan(at, na, times(na, -1), -std.math.pi, half);
        return .{};
    }
    // The outer side is the one the path turns away from.
    const turn: f32 = if (cross > 0) 1 else -1;
    const oa = times(na, -turn);
    const ob = times(nb, -turn);
    const square = 1 + dot < 1e-6;
    switch (how.join) {
        .round => sink.fan(at, oa, ob, turn * std.math.atan2(@abs(cross), dot), half),
        .bevel => sink.piece(&.{ at, add(at, oa), add(at, ob) }),
        .miter => {
            const miter = if (square) oa else times(add(oa, ob), 1 / (1 + dot));
            const length = @sqrt(miter.x * miter.x + miter.y * miter.y);
            if (!square and length <= how.miter_limit * half) {
                sink.piece(&.{ at, add(at, oa), add(at, miter), add(at, ob) });
            } else {
                sink.piece(&.{ at, add(at, oa), add(at, ob) });
            }
        },
    }
    if (square) return .{};
    // The inner edges cross `back` from the corner along each. Cut there,
    // each segment gives up what lies past the line from the crossing to
    // the corner, and the other must hold it: so each must reach as far
    // as the crossing and as the other's inner corner, past what its
    // other end's corner took. Else both stay square, and overlap.
    const back = half * @abs(cross) / (1 + dot);
    const need = @max(back, half * @abs(cross));
    if (!(need <= in.length - in.start.need and need <= out.length - far.need)) return .{};
    return .{ .side = turn, .at = add(at, times(add(na, nb), turn / (1 + dot))), .need = need };
}

/// An open end at `at`, the segment there going `along`; `away` 1 at
/// the contour's end, -1 at its start.
fn cap(sink: *Sink, at: P, along: P, away: f32, how: How) void {
    const n = normal(along, how.half);
    switch (how.cap) {
        .butt => {},
        // Half a disc, from the segment's one corner to its other.
        .round => if (away > 0)
            sink.fan(at, n, times(n, -1), -std.math.pi, how.half)
        else
            sink.fan(at, times(n, -1), n, -std.math.pi, how.half),
        .square => {
            const out = add(at, times(along, away * how.half));
            sink.piece(&.{ add(at, n), add(out, n), sub(out, n), sub(at, n) });
        },
    }
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

/// The stroke of `points`, its coverage summed over the canvas.
fn area(points: []const P, smooth: []const bool, closed: bool, how: How, size: u32) !f32 {
    const floats = try testing.allocator.alloc(f32, coverage_.Coverage.floats(size, size));
    defer testing.allocator.free(floats);
    @memset(floats, 0);
    var coverage = coverage_.Coverage{ .acc = floats.ptr, .width = size, .height = size, .band_end = size };
    var sink = Sink.of(&coverage, .{});
    contour(&sink, points, smooth, closed, how);
    var total: f32 = 0;
    var most: f32 = 0;
    for (0..size) |y| {
        const row = coverage.row(@intCast(y));
        var winding: f32 = 0;
        for (0..size) |x| {
            winding += row[x];
            total += @min(@abs(winding), 1);
            most = @max(most, @abs(winding));
        }
    }
    // Nowhere does a piece lie over another.
    try testing.expect(most < 1.001);
    return total;
}

test "a corner's pieces meet edge to edge: an L's area is its two arms' and the miter's" {
    const l = [_]P{ .{ .x = 4, .y = 4 }, .{ .x = 20, .y = 4 }, .{ .x = 20, .y = 20 } };
    const flags = [_]bool{false} ** 3;
    // Arms 16 long and 4 wide, the 2 by 2 inside the corner theirs both,
    // and the miter's square outside it, or the bevel's half of it.
    try testing.expectApproxEqAbs(@as(f32, 2 * 16 * 4 - 4 + 4), try area(&l, &flags, false, .{ .half = 2 }, 32), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 2 * 16 * 4 - 4 + 2), try area(&l, &flags, false, .{ .half = 2, .join = .bevel }, 32), 0.01);
    // Turning the other way, the same.
    const back = [_]P{ l[2], l[1], l[0] };
    try testing.expectApproxEqAbs(@as(f32, 2 * 16 * 4), try area(&back, &flags, false, .{ .half = 2 }, 32), 0.01);
}

test "a sharp corner cut too, where its segments are long enough" {
    // 19 degrees: the inner edges cross 15 back, 24 long segments.
    const v = [_]P{ .{ .x = 6, .y = 40 }, .{ .x = 30, .y = 44 }, .{ .x = 6, .y = 48 } };
    const flags = [_]bool{false} ** 3;
    _ = try area(&v, &flags, false, .{ .half = 2.5, .miter_limit = 10 }, 64);
    _ = try area(&v, &flags, false, .{ .half = 2.5, .join = .round }, 64);
}

test "a closed square and a round-capped line come out at their areas" {
    const square = [_]P{ .{ .x = 4, .y = 4 }, .{ .x = 20, .y = 4 }, .{ .x = 20, .y = 20 }, .{ .x = 4, .y = 20 } };
    const flags = [_]bool{false} ** 4;
    // 20 square less the 12 inside.
    try testing.expectApproxEqAbs(@as(f32, 20 * 20 - 12 * 12), try area(&square, &flags, true, .{ .half = 2 }, 32), 0.01);
    // The last point back on the first: the same.
    const again = square ++ [_]P{square[0]};
    const again_flags = flags ++ [_]bool{false};
    try testing.expectApproxEqAbs(@as(f32, 20 * 20 - 12 * 12), try area(&again, &again_flags, true, .{ .half = 2 }, 32), 0.01);
    // A line 16 long, 4 wide, and two half discs of radius 2 in 8 sides
    // each: one disc's octagon, 8 r² sin(45°) / 2.
    const line = [_]P{ .{ .x = 8, .y = 8 }, .{ .x = 24, .y = 8 } };
    const octagon = 8 * 4 * @sin(@as(f32, std.math.pi / 4.0)) / 2;
    try testing.expectApproxEqAbs(16 * 4 + octagon, try area(&line, flags[0..2], false, .{ .half = 2, .cap = .round }, 32), 0.01);
}

test "a curve's points joined round, and nowhere twice over" {
    // A quarter circle of radius 12 in 16 lines.
    var arc: [17]P = undefined;
    var flags: [17]bool = undefined;
    for (&arc, &flags, 0..) |*p, *f, i| {
        const t = @as(f32, @floatFromInt(i)) / 16 * std.math.pi / 2;
        p.* = .{ .x = 4 + 12 * @cos(t), .y = 4 + 12 * @sin(t) };
        f.* = i > 0 and i < 16;
    }
    // A quarter ring between radii 10 and 14, near enough.
    const ring = std.math.pi / 4.0 * (14 * 14 - 10 * 10);
    try testing.expectApproxEqRel(@as(f32, ring), try area(&arc, &flags, false, .{ .half = 2 }, 24), 0.01);
}
