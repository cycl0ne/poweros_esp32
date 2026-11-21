// SPDX-License-Identifier: MIT
//! A path measured: how long it is, where along it a distance comes to
//! and which way it goes there, and its vertices with the directions in
//! and out of each. Since 1.5: SVG's `textPath`, `pathLength` and
//! markers.
//!
//! **Lengths** are taken through the matrix given, in the units it takes
//! the path to, each curve cut into as many lines as Wang's bound says
//! keep within a hundredth of a unit of it. A close is the line back to
//! the contour's start; a move goes nowhere and adds nothing, so the
//! contours follow one another along the length. A place along a curve
//! is on the curve, at the parameter its line's share gives, and the way
//! the curve goes there is its own tangent, not its line's.
//!
//! **Vertices** are one a segment: a move's point, the end of each line
//! and curve, and a close's - the contour's start. An arc is the curves
//! it was made of, each a quarter turn or less, so the places they meet
//! are vertices too, as a drawing that breaks arcs so puts markers at
//! them. The direction into a vertex is where its segment ends up going:
//! toward the end from the last control point that is not on it, or from
//! where it began. Out of it, where the next segment starts going. A
//! segment of no length takes its direction from the segment before it,
//! or the one after; the first and last vertex of a closed contour are
//! come into by its close and go out by its first segment.

const sdk = @import("sdk");
const vector = sdk.vector;
const P = vector.Point;
const Matrix = vector.Matrix;
const path_ = @import("path.zig");
const Path = path_.Path;
const Verb = path_.Verb;

/// How far the lines a curve is cut into may stray from it.
const tolerance: f32 = 0.01;
/// The most lines a curve is cut into.
const most_pieces: u32 = 1024;

/// How many lines keep the curve with control points `points` - its
/// start first - within `tolerance`.
fn piecesOf(points: []const P) u32 {
    var most: f32 = 0;
    var index: usize = 0;
    while (index + 2 < points.len) : (index += 1) {
        const dx = points[index].x - 2 * points[index + 1].x + points[index + 2].x;
        const dy = points[index].y - 2 * points[index + 1].y + points[index + 2].y;
        most = @max(most, @sqrt(dx * dx + dy * dy));
    }
    // Wang: a quad's second difference counts once, a cubic's 3/4 of it
    // twice over (n(n-1)/8 with n its degree).
    const weight: f32 = if (points.len == 4) 0.75 else 0.25;
    const pieces = @ceil(@sqrt(weight * most / tolerance));
    if (!(pieces >= 1)) return 1;
    return @intFromFloat(@min(pieces, @as(f32, @floatFromInt(most_pieces))));
}

/// The lines of a curve each say which part of it they stand for.
const Piece = struct { points: []const P, from: f32, to: f32 };

/// The way the curve with control points `points` goes at `t`: its
/// derivative.
fn tangent(points: []const P, fraction: f32) P {
    const rest = 1 - fraction;
    if (points.len == 3) return .{
        .x = 2 * (rest * (points[1].x - points[0].x) + fraction * (points[2].x - points[1].x)),
        .y = 2 * (rest * (points[1].y - points[0].y) + fraction * (points[2].y - points[1].y)),
    };
    return .{
        .x = 3 * (rest * rest * (points[1].x - points[0].x) + 2 * rest * fraction * (points[2].x - points[1].x) + fraction * fraction * (points[3].x - points[2].x)),
        .y = 3 * (rest * rest * (points[1].y - points[0].y) + 2 * rest * fraction * (points[2].y - points[1].y) + fraction * fraction * (points[3].y - points[2].y)),
    };
}

fn bezier(points: []const P, fraction: f32) P {
    const rest = 1 - fraction;
    if (points.len == 3) return .{
        .x = rest * rest * points[0].x + 2 * rest * fraction * points[1].x + fraction * fraction * points[2].x,
        .y = rest * rest * points[0].y + 2 * rest * fraction * points[1].y + fraction * fraction * points[2].y,
    };
    return .{
        .x = rest * rest * rest * points[0].x + 3 * rest * rest * fraction * points[1].x + 3 * rest * fraction * fraction * points[2].x + fraction * fraction * fraction * points[3].x,
        .y = rest * rest * rest * points[0].y + 3 * rest * rest * fraction * points[1].y + 3 * rest * fraction * fraction * points[2].y + fraction * fraction * fraction * points[3].y,
    };
}

/// Every line the path comes to through `matrix`, in order, handed to
/// `context.line(from, to, piece)` - `piece` the part of a curve it
/// stands for, null for a line of the path's own; false from it stops
/// the walk.
fn lines(path: *const Path, matrix: Matrix, context: anytype) void {
    var walk = path.walk();
    var at = P{};
    var start = P{};
    var begun = false;
    while (walk.next()) |segment| {
        const pts = segment.points;
        switch (segment.verb) {
            .move => {
                at = matrix.apply(pts[0]);
                start = at;
                begun = true;
                if (!context.move(at)) return;
            },
            .line => {
                if (!begun) continue;
                const to = matrix.apply(pts[0]);
                if (!context.line(at, to, null)) return;
                at = to;
            },
            .quad, .cubic => {
                if (!begun) continue;
                var control: [4]P = undefined;
                control[0] = at;
                for (pts, 1..) |point, index| control[index] = matrix.apply(point);
                const all = control[0 .. pts.len + 1];
                const pieces = piecesOf(all);
                const count: f32 = @floatFromInt(pieces);
                var index: u32 = 1;
                while (index <= pieces) : (index += 1) {
                    const fraction = @as(f32, @floatFromInt(index)) / count;
                    const to = if (index == pieces) all[all.len - 1] else bezier(all, fraction);
                    const piece = Piece{ .points = all, .from = @as(f32, @floatFromInt(index - 1)) / count, .to = fraction };
                    if (!context.line(at, to, piece)) return;
                    at = to;
                }
            },
            .close => {
                if (!begun) continue;
                if (!context.line(at, start, null)) return;
                at = start;
            },
        }
    }
}

fn distance(from: P, to: P) f32 {
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    return @sqrt(dx * dx + dy * dy);
}

/// The path's length through `matrix`.
pub fn length(path: *const Path, matrix: Matrix) f32 {
    const Sum = struct {
        total: f32 = 0,
        fn move(_: *@This(), _: P) bool {
            return true;
        }
        fn line(sum: *@This(), from: P, to: P, _: ?Piece) bool {
            sum.total += distance(from, to);
            return true;
        }
    };
    var sum = Sum{};
    lines(path, matrix, &sum);
    return sum.total;
}

/// A place along a path, and the way it goes there in degrees,
/// clockwise from across.
pub const Place = struct { point: P, angle: f32 };

/// Where `along` comes to along the path through `matrix`; null before
/// its start or past its end, or on a path of no length. At a vertex,
/// the way out of it - the way in at the path's very end.
pub fn pointAt(path: *const Path, matrix: Matrix, along: f32) ?Place {
    if (!(along >= 0)) return null;
    const Find = struct {
        left: f32,
        found: ?Place = null,
        /// The last line of any length, for the very end.
        last: ?Place = null,
        fn move(_: *@This(), _: P) bool {
            return true;
        }
        fn line(find: *@This(), from: P, to: P, piece: ?Piece) bool {
            const span = distance(from, to);
            if (!(span > 0)) return true;
            const angle = angleOf(to.x - from.x, to.y - from.y);
            if (find.left < span) {
                const share = find.left / span;
                find.found = .{ .point = .{ .x = from.x + (to.x - from.x) * share, .y = from.y + (to.y - from.y) * share }, .angle = angle };
                if (piece) |curve| find.found = onCurve(curve, curve.from + (curve.to - curve.from) * share) orelse find.found;
                return false;
            }
            find.left -= span;
            find.last = .{ .point = to, .angle = angle };
            if (piece) |curve| find.last = onCurve(curve, curve.to) orelse find.last;
            return true;
        }

        /// The place at `t` on the curve, the way it goes there; null
        /// where it stands still.
        fn onCurve(curve: Piece, fraction: f32) ?Place {
            const way = tangent(curve.points, fraction);
            if (way.x == 0 and way.y == 0) return null;
            return .{ .point = bezier(curve.points, fraction), .angle = angleOf(way.x, way.y) };
        }
    };
    var find = Find{ .left = along };
    lines(path, matrix, &find);
    if (find.found) |place| return place;
    // Exactly at the end, within a rounding.
    if (find.last) |last| if (find.left <= 1e-3) return last;
    return null;
}

/// A direction's angle in degrees, 0 to 360, clockwise from across (y
/// grows down).
pub fn angleOf(dx: f32, dy: f32) f32 {
    if (dx == 0 and dy == 0) return 0;
    var degrees = atan2(dy, dx) * (180.0 / 3.14159265358979);
    if (degrees < 0) degrees += 360;
    if (degrees >= 360) degrees -= 360;
    return degrees;
}

/// The arc tangent of y over x, the whole way round.
fn atan2(y: f32, x: f32) f32 {
    const pi: f32 = 3.14159265358979;
    if (x == 0) return if (y > 0) pi / 2 else if (y < 0) -pi / 2 else 0;
    const angle = atan(y / x);
    if (x > 0) return angle;
    return if (y >= 0) angle + pi else angle - pi;
}

fn atan(ratio: f32) f32 {
    const pi: f32 = 3.14159265358979;
    // Brought into -1 to 1, then into a third of it, and the series.
    if (ratio > 1) return pi / 2 - atan(1 / ratio);
    if (ratio < -1) return -pi / 2 - atan(1 / ratio);
    const tan_sixth: f32 = 0.267949192; // tan(15 degrees)
    if (ratio > tan_sixth) return pi / 6 + atan((ratio * 1.732050808 - 1) / (ratio + 1.732050808));
    if (ratio < -tan_sixth) return -pi / 6 + atan((ratio * 1.732050808 + 1) / (1.732050808 - ratio));
    const squared = ratio * ratio;
    return ratio * (1 - squared * (1.0 / 3.0 - squared * (1.0 / 5.0 - squared * (1.0 / 7.0 - squared / 9.0))));
}

// --- vertices -----------------------------------------------------------------

/// A segment as the vertices see it: its verb, its points, and where it
/// begins.
const Seg = struct {
    verb: Verb,
    /// Its control points and end; a close's end is the contour's start.
    points: [3]P,
    count: u32,
    from: P,
    /// Where it ends.
    to: P,
};

/// A direction between two points.
const Way = struct { from: P, to: P };

fn same(one: P, other: P) bool {
    return @abs(one.x - other.x) <= 1e-5 and @abs(one.y - other.y) <= 1e-5;
}

/// Which way the segment starts going: toward its first point that is
/// not where it begins.
fn startWay(seg: Seg) ?Way {
    if (seg.verb == .move) return null;
    for (seg.points[0..seg.count]) |point| if (!same(seg.from, point)) return .{ .from = seg.from, .to = point };
    return null;
}

/// Which way it ends up going: from its last point - before the end -
/// that is not where it ends.
fn endWay(seg: Seg) ?Way {
    if (seg.verb == .move) return null;
    var index = seg.count;
    while (index > 1) {
        index -= 1;
        if (!same(seg.points[index - 1], seg.to)) return .{ .from = seg.points[index - 1], .to = seg.to };
    }
    if (!same(seg.from, seg.to)) return .{ .from = seg.from, .to = seg.to };
    return null;
}

fn wayAngle(way: Way) f32 {
    return angleOf(way.to.x - way.from.x, way.to.y - way.from.y);
}

/// The path's vertices into `out`, as many as it has room for; how many
/// there are.
pub fn vertices(path: *const Path, out: []vector.Vertex) u32 {
    var segments = Segments.of(path);
    defer segments.deinit();
    const total = segments.count;
    var contour_start: u32 = 0;
    while (contour_start < total) {
        var contour_end = contour_start + 1;
        while (contour_end < total and segments.verbs[contour_end] != .move) contour_end += 1;
        const closed = segments.verbs[contour_end - 1] == .close;
        var index = contour_start;
        while (index < contour_end and index < out.len) : (index += 1) {
            const seg = segments.at(index);
            var preceding: ?u32 = null;
            var following: ?u32 = null;
            if (closed and (seg.verb == .move or seg.verb == .close)) {
                preceding = contour_end - 1;
                if (contour_start + 1 < contour_end) following = contour_start + 1;
            } else {
                if (index > contour_start) preceding = index;
                if (index + 1 < contour_end) following = index + 1;
            }
            const in = if (preceding) |before| segments.endDirection(contour_start, contour_end, before) else null;
            const out_way = if (following) |after| segments.startDirection(contour_start, contour_end, after) else null;
            var flags: u32 = 0;
            if (seg.verb == .move) flags |= vector.VERTEXF_START;
            if (index + 1 == contour_end) flags |= vector.VERTEXF_END;
            if (seg.verb == .close) flags |= vector.VERTEXF_CLOSED;
            var in_angle: f32 = 0;
            var out_angle: f32 = 0;
            if (in) |way| in_angle = wayAngle(way) else flags |= vector.VERTEXF_NO_IN;
            if (out_way) |way| out_angle = wayAngle(way) else flags |= vector.VERTEXF_NO_OUT;
            if (in == null and out_way != null) in_angle = out_angle;
            if (out_way == null and in != null) out_angle = in_angle;
            out[index] = .{ .point = seg.to, .in_angle = in_angle, .out_angle = out_angle, .flags = flags };
        }
        contour_start = contour_end;
    }
    return total;
}

/// The path's segments by their numbers: where each one's points are,
/// from a table made once - or, without the memory for it, found by
/// walking from the start each time.
const Segments = struct {
    path: *const Path,
    verbs: []const Verb,
    points: []const P,
    count: u32,
    /// Where each segment's points begin.
    offsets: ?[]u32,

    fn of(path: *const Path) Segments {
        const verbs = path.verbs.items();
        var segments = Segments{ .path = path, .verbs = verbs, .points = path.points.items(), .count = @intCast(verbs.len), .offsets = null };
        if (path.memory.alloc(u32, verbs.len)) |offsets| {
            var next: u32 = 0;
            for (verbs, offsets) |verb, *offset| {
                offset.* = next;
                next += verb.points();
            }
            segments.offsets = offsets;
        }
        return segments;
    }

    fn deinit(segments: *Segments) void {
        if (segments.offsets) |offsets| segments.path.memory.free(u32, offsets);
    }

    fn offsetOf(segments: *const Segments, index: u32) u32 {
        if (segments.offsets) |offsets| return offsets[index];
        var offset: u32 = 0;
        for (segments.verbs[0..index]) |verb| offset += verb.points();
        return offset;
    }

    /// Where the contour segment `i` is in starts.
    fn contourStart(segments: *const Segments, index: u32) P {
        var next = index + 1;
        while (next > 0) {
            next -= 1;
            if (segments.verbs[next] == .move) return segments.points[segments.offsetOf(next)];
        }
        return .{};
    }

    /// Where segment `i` ends.
    fn endOf(segments: *const Segments, index: u32) P {
        const verb = segments.verbs[index];
        if (verb == .close) return segments.contourStart(index);
        return segments.points[segments.offsetOf(index) + verb.points() - 1];
    }

    fn at(segments: *const Segments, index: u32) Seg {
        const verb = segments.verbs[index];
        const from = if (index == 0) P{} else segments.endOf(index - 1);
        var seg = Seg{ .verb = verb, .points = undefined, .count = verb.points(), .from = from, .to = undefined };
        if (verb == .close) {
            seg.points[0] = segments.contourStart(index);
            seg.count = 1;
        } else {
            const offset = segments.offsetOf(index);
            for (0..seg.count) |point| seg.points[point] = segments.points[offset + point];
        }
        seg.to = seg.points[seg.count - 1];
        return seg;
    }

    /// Where segment `i` starts going, or - of no length - where the one
    /// before it ended up going, or the one after starts.
    fn startDirection(segments: *const Segments, first: u32, end: u32, index: u32) ?Way {
        if (startWay(segments.at(index))) |way| return way;
        var next = index;
        while (next > first + 1) {
            next -= 1;
            if (endWay(segments.at(next))) |way| return way;
        }
        next = index + 1;
        while (next < end) : (next += 1) if (startWay(segments.at(next))) |way| return way;
        return null;
    }

    /// Where segment `i` ends up going, or - of no length - where the one
    /// after it starts, or the one before ended.
    fn endDirection(segments: *const Segments, first: u32, end: u32, index: u32) ?Way {
        if (endWay(segments.at(index))) |way| return way;
        var next = index + 1;
        while (next < end) : (next += 1) if (startWay(segments.at(next))) |way| return way;
        next = index;
        while (next > first + 1) {
            next -= 1;
            if (endWay(segments.at(next))) |way| return way;
        }
        return null;
    }
};

// --- tests ---------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;
const test_memory = @import("memory.zig").test_memory;
const shapes = @import("shapes.zig");

test "a length, lines and a close; through a matrix; a circle's" {
    const path = Path.create(test_memory).?;
    defer path.destroy();
    path.moveTo(.{ .x = 0, .y = 0 });
    path.lineTo(.{ .x = 30, .y = 0 });
    path.lineTo(.{ .x = 30, .y = 40 });
    path.close();
    try testing.expectApproxEqAbs(@as(f32, 120), length(path, .{}), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 240), length(path, .{ .a = 2, .d = 2 }), 0.001);
    path.clear();
    shapes.addEllipse(path, .{ .x = 50, .y = 50 }, 10, 10);
    try testing.expectApproxEqAbs(@as(f32, 2 * 3.14159265 * 10), length(path, .{}), 0.02);
}

test "a point along: on a line, round a corner, at the end, and past it" {
    const path = Path.create(test_memory).?;
    defer path.destroy();
    path.moveTo(.{ .x = 0, .y = 0 });
    path.lineTo(.{ .x = 10, .y = 0 });
    path.lineTo(.{ .x = 10, .y = 10 });
    const on_first = pointAt(path, .{}, 5).?;
    try testing.expectEqual(P{ .x = 5, .y = 0 }, on_first.point);
    try testing.expectEqual(@as(f32, 0), on_first.angle);
    const on_second = pointAt(path, .{}, 15).?;
    try testing.expectEqual(P{ .x = 10, .y = 5 }, on_second.point);
    try testing.expectApproxEqAbs(@as(f32, 90), on_second.angle, 0.001);
    const end = pointAt(path, .{}, 20).?;
    try testing.expectEqual(P{ .x = 10, .y = 10 }, end.point);
    try testing.expectEqual(@as(?Place, null), pointAt(path, .{}, 21));
    try testing.expectEqual(@as(?Place, null), pointAt(path, .{}, -1));
}

test "a point along a curve: on the curve, going the way it goes there" {
    const path = Path.create(test_memory).?;
    defer path.destroy();
    path.moveTo(.{ .x = 0, .y = 0 });
    path.quadTo(.{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 });
    // Halfway along this one is halfway through it, its tangent a
    // diagonal; at its ends, across and down.
    const middle = pointAt(path, .{}, length(path, .{}) / 2).?;
    try testing.expectApproxEqAbs(@as(f32, 7.5), middle.point.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 2.5), middle.point.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 45), middle.angle, 0.05);
    try testing.expectApproxEqAbs(@as(f32, 0), pointAt(path, .{}, 0).?.angle, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 90), pointAt(path, .{}, length(path, .{})).?.angle, 0.001);
}

test "vertices: an open polyline, a closed triangle, and a segment of no length" {
    const path = Path.create(test_memory).?;
    defer path.destroy();
    path.moveTo(.{ .x = 0, .y = 0 });
    path.lineTo(.{ .x = 10, .y = 0 });
    path.lineTo(.{ .x = 10, .y = 10 });
    var out: [8]vector.Vertex = undefined;
    try testing.expectEqual(@as(u32, 3), vertices(path, &out));
    try testing.expectEqual(vector.VERTEXF_START | vector.VERTEXF_NO_IN, out[0].flags);
    try testing.expectEqual(@as(f32, 0), out[0].out_angle);
    try testing.expectEqual(@as(f32, 0), out[1].in_angle);
    try testing.expectApproxEqAbs(@as(f32, 90), out[1].out_angle, 0.001);
    try testing.expectEqual(vector.VERTEXF_END | vector.VERTEXF_NO_OUT, out[2].flags);

    path.clear();
    path.moveTo(.{ .x = 0, .y = 0 });
    path.lineTo(.{ .x = 10, .y = 0 });
    path.lineTo(.{ .x = 0, .y = 10 });
    path.close();
    try testing.expectEqual(@as(u32, 4), vertices(path, &out));
    // The start is come into by the close, going up.
    try testing.expectApproxEqAbs(@as(f32, 270), out[0].in_angle, 0.001);
    try testing.expectEqual(@as(f32, 0), out[0].out_angle);
    try testing.expectEqual(P{ .x = 0, .y = 0 }, out[3].point);
    try testing.expect(out[3].flags & vector.VERTEXF_CLOSED != 0);

    path.clear();
    path.moveTo(.{ .x = 0, .y = 0 });
    path.lineTo(.{ .x = 10, .y = 0 });
    path.lineTo(.{ .x = 10, .y = 0 });
    path.lineTo(.{ .x = 10, .y = 10 });
    _ = vertices(path, &out);
    // The vertex after the empty line: come into as the next line goes,
    // the one after it - the way its own segment would have taken.
    try testing.expectApproxEqAbs(@as(f32, 90), out[2].in_angle, 0.001);
    // The one before it: in and out as the first line goes.
    try testing.expectEqual(@as(f32, 0), out[1].in_angle);
    try testing.expectEqual(@as(f32, 0), out[1].out_angle);
    try testing.expectApproxEqAbs(@as(f32, 90), out[2].out_angle, 0.001);
    // Room for fewer: as many filled, all counted.
    try testing.expectEqual(@as(u32, 4), vertices(path, out[0..1]));
}

test "angles all the way round" {
    try testing.expectApproxEqAbs(@as(f32, 45), angleOf(1, 1), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 135), angleOf(-1, 1), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 180), angleOf(-1, 0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 300), angleOf(0.5, -0.8660254), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.4636476), atan(0.5), 0.000001);
    try testing.expectApproxEqAbs(@as(f32, 1.3734008), atan(5), 0.000001);
}
