// SPDX-License-Identifier: MIT
//! A glyph's contours as segments: the verbs and points vector.library's
//! `AddSegments` takes, in the font's units. Since 1.2.
//!
//! A contour starts at its first point on the curve - or, with none on
//! it, halfway between its last point and its first - and goes round:
//! a point on the curve after one on it is a line to it, one off the
//! curve the control point of a quadratic curve to the next on it, or to
//! halfway to the next off it, which is on the curve though not in the
//! file. The line back to the start is the close's.

const sdk = @import("sdk");
const vector = sdk.vector;
const truetype = sdk.truetype;
const exec = sdk.exec;
const _outline = @import("../outline/_outline.zig");
const Font = _outline.Font;
const Point = _outline.Point;
const ExecBase = sdk.interface.exec.ExecBase;

/// Segments written while they fit, and counted whether or not.
const Writer = struct {
    out: *truetype.Segments,
    verbs: u32 = 0,
    points: u32 = 0,

    fn verb(w: *Writer, v: u8, ps: []const vector.Point) void {
        if (w.verbs < w.out.verb_room and w.points + ps.len <= w.out.point_room) {
            w.out.verbs[w.verbs] = v;
            for (ps, 0..) |p, i| w.out.points[w.points + i] = p;
        }
        w.verbs += 1;
        w.points += @intCast(ps.len);
    }

    fn fits(w: *const Writer) bool {
        return w.verbs <= w.out.verb_room and w.points <= w.out.point_room;
    }
};

fn at(p: Point) vector.Point {
    return .{ .x = p.x, .y = p.y };
}

fn halfway(a: vector.Point, b: vector.Point) vector.Point {
    return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
}

/// The contours read into `c` as segments into `out`.
pub fn write(c: *const _outline.Contours, out: *truetype.Segments) i32 {
    var w = Writer{ .out = out };
    var start: u32 = 0;
    for (c.ends[0..c.end_count]) |end| {
        defer start = end;
        if (end <= start + 1) continue;
        contour(&w, c.points[start..end]);
    }
    out.verb_count = w.verbs;
    out.point_count = w.points;
    return if (w.fits()) truetype.TRUETYPE_OK else truetype.TRUETYPEERR_ROOM;
}

fn contour(w: *Writer, ps: []const Point) void {
    const n = ps.len;
    // Where it starts, and which point is the first after it.
    var first_on: ?usize = null;
    for (ps, 0..) |p, i| if (p.on) {
        first_on = i;
        break;
    };
    const origin = if (first_on) |f| at(ps[f]) else halfway(at(ps[n - 1]), at(ps[0]));
    const from: usize = if (first_on) |f| f + 1 else 0;
    w.verb(vector.SEG_MOVE, &.{origin});
    var control: ?vector.Point = null;
    for (0..n) |k| {
        const p = ps[(from + k) % n];
        // The last of the round is the start again, on the curve.
        const last = k == n - 1 and first_on != null;
        const q = at(p);
        if (p.on) {
            if (control) |cp| {
                w.verb(vector.SEG_QUAD, &.{ cp, q });
                control = null;
            } else if (!last) w.verb(vector.SEG_LINE, &.{q});
        } else {
            if (control) |cp| w.verb(vector.SEG_QUAD, &.{ cp, halfway(cp, q) });
            control = q;
        }
    }
    if (control) |cp| w.verb(vector.SEG_QUAD, &.{ cp, origin });
    w.verb(vector.SEG_CLOSE, &.{});
}

/// `glyph` of `font` as segments into `out`.
pub fn glyphSegments(sys: *ExecBase, font: *const Font, glyph: u32, out: *truetype.Segments) i32 {
    out.verb_count = 0;
    out.point_count = 0;
    if (glyph >= font.glyph_count) return truetype.TRUETYPEERR_GLYPH;
    const points, const contours = roomOf(font);
    const bytes = points * @sizeOf(Point) + contours * 4 + points;
    const memory = sys.AllocVec(bytes, exec.MEMF_ANY) orelse return truetype.TRUETYPEERR_NOMEM;
    defer sys.FreeVec(memory);
    const base: [*]u8 = @ptrCast(memory);
    const point_area: [*]Point = @ptrCast(@alignCast(base));
    const ends: [*]u32 = @ptrCast(@alignCast(base + points * @sizeOf(Point)));
    const flags = base + points * @sizeOf(Point) + contours * 4;
    var c = _outline.Contours{ .points = point_area[0..points], .ends = ends[0..contours], .flags = flags[0..points] };
    const identity = [6]f32{ 1, 0, 0, 1, 0, 0 };
    if (!_outline.contours(font, glyph, &c, identity, 0)) return truetype.TRUETYPEERR_GLYPH;
    return write(&c, out);
}

/// The points and the contours a glyph of `font` is read with: one more
/// of each than the font says its largest glyph has.
fn roomOf(font: *const Font) [2]u32 {
    return .{ font.max_points + 1, font.max_contours + 1 };
}

/// The most verbs and points a glyph of `font` takes as segments: a move
/// and a close a contour, and a segment a point of it, of two points at
/// most - of as many points and contours as a glyph is read with.
pub fn mostOf(font: *const Font) [2]u32 {
    const points, const contours = roomOf(font);
    return .{ points + 2 * contours, 2 * points + contours };
}

// --- tests ---------------------------------------------------------------------

const testing = @import("std").testing;

test "contours as segments: lines, a curve, two off the curve in a row, none on it" {
    var points = [_]Point{
        // A triangle, on the curve.
        .{ .x = 0, .y = 0, .on = true },   .{ .x = 10, .y = 0, .on = true }, .{ .x = 5, .y = 10, .on = true },
        // A curve starting off it: off, on, off, off.
        .{ .x = 0, .y = 5, .on = false },  .{ .x = 5, .y = 0, .on = true },  .{ .x = 10, .y = 5, .on = false },
        .{ .x = 5, .y = 10, .on = false },
        // A circle of four off the curve.
        .{ .x = 0, .y = 0, .on = false }, .{ .x = 4, .y = 0, .on = false },
        .{ .x = 4, .y = 4, .on = false },  .{ .x = 0, .y = 4, .on = false },
    };
    var ends = [_]u32{ 3, 7, 11 };
    var flags: [1]u8 = undefined;
    const c = _outline.Contours{ .points = &points, .ends = &ends, .flags = &flags, .point_count = 11, .end_count = 3 };
    var verbs: [32]u8 = undefined;
    var ps: [32]vector.Point = undefined;
    var out = truetype.Segments{ .verbs = &verbs, .points = &ps, .verb_room = 32, .point_room = 32 };
    try testing.expectEqual(truetype.TRUETYPE_OK, write(&c, &out));
    const M = vector.SEG_MOVE;
    const L = vector.SEG_LINE;
    const Q = vector.SEG_QUAD;
    const C = vector.SEG_CLOSE;
    try testing.expectEqualSlices(u8, &.{ M, L, L, C, M, Q, Q, Q, C, M, Q, Q, Q, Q, C }, verbs[0..out.verb_count]);
    // The triangle: from its first point, the line back is the close's.
    try testing.expectEqual(vector.Point{ .x = 0, .y = 0 }, ps[0]);
    try testing.expectEqual(vector.Point{ .x = 5, .y = 10 }, ps[2]);
    // The curve: from (5,0) through (10,5) to halfway to (5,10)'s next...
    try testing.expectEqual(vector.Point{ .x = 5, .y = 0 }, ps[3]);
    try testing.expectEqual(vector.Point{ .x = 10, .y = 5 }, ps[4]);
    try testing.expectEqual(vector.Point{ .x = 7.5, .y = 7.5 }, ps[5]);
    // ... and round to its start through the one it began off.
    try testing.expectEqual(vector.Point{ .x = 0, .y = 5 }, ps[8]);
    try testing.expectEqual(vector.Point{ .x = 5, .y = 0 }, ps[9]);
    // The circle starts halfway from its last point to its first.
    try testing.expectEqual(vector.Point{ .x = 0, .y = 2 }, ps[10]);
    try testing.expectEqual(@as(u32, 19), out.point_count);

    // Too short: nothing past the room written, the counts what it needs.
    var short = truetype.Segments{ .verbs = &verbs, .points = &ps, .verb_room = 4, .point_room = 32 };
    try testing.expectEqual(truetype.TRUETYPEERR_ROOM, write(&c, &short));
    try testing.expectEqual(@as(u32, 15), short.verb_count);
    try testing.expectEqual(@as(u32, 19), short.point_count);
}
