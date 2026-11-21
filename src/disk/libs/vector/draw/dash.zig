// SPDX-License-Identifier: MIT
//! A stroke's dashes: each flattened contour cut where its dashes and
//! gaps end, in the path's own units, and every dash handed on to be
//! stroked as an open contour with its caps. Since 1.1.
//!
//! The lengths go on from one contour's line to the next, and round a
//! closed contour back to where it began: there, a dash still going at
//! the end is joined to the one the contour started with, so a closed
//! shape has no seam. A contour that no dash or gap ends on is stroked as
//! it is, closed if it was.
//!
//! As SVG has it, an odd count of lengths is gone through twice, and
//! lengths that are negative or come to nothing draw the stroke whole. A
//! dash of no length is still handed on, with the way the path goes
//! there (`along`), so that its caps are drawn: a dot, or a square turned
//! with the path.
//! A stroke is cut at most `max_cuts` times; past that it goes on as the
//! dash or the gap it is in.
//!
//! Since 1.5 a dash goes with the way the curve it was cut from goes at
//! its ends (`ends`, from `stroke.tangentAt`), which its ends are cut
//! across.

const sdk = @import("sdk");
const vector = sdk.vector;
const P = vector.Point;
const memory_ = @import("memory.zig");
const Memory = memory_.Memory;
const List = memory_.List;
const flatten = @import("flatten.zig");
const stroke_ = @import("stroke.zig");

pub const max_cuts = 1 << 16;

pub const Pattern = struct {
    values: []const f32,
    /// The entries of a period: the lengths given, twice when odd.
    count: usize,
    /// Where the dashes start: how far into a period, and in which entry
    /// and how much of it is left.
    first: usize,
    first_left: f32,

    /// Null when the stroke is drawn whole.
    pub fn of(stroke: *const vector.Stroke) ?Pattern {
        const given = stroke.dashes orelse return null;
        if (stroke.dash_count == 0) return null;
        const values = given[0..stroke.dash_count];
        var sum: f32 = 0;
        for (values) |v| {
            if (!(v >= 0)) return null;
            sum += v;
        }
        const count = if (values.len % 2 == 1) values.len * 2 else values.len;
        const total = if (values.len % 2 == 1) sum * 2 else sum;
        if (!(total > 0) or total == @import("std").math.inf(f32)) return null;
        var pattern = Pattern{ .values = values, .count = count, .first = 0, .first_left = 0 };
        var phase = stroke.dash_offset;
        if (phase != phase or @abs(phase) == @import("std").math.inf(f32)) phase = 0;
        phase -= total * @floor(phase / total);
        var i: usize = 0;
        var guard: usize = 0;
        // A dash of no length where the dashes start is drawn.
        while (phase > 0 and phase >= pattern.value(i) and guard < 2 * count) : (guard += 1) {
            phase -= pattern.value(i);
            i = (i + 1) % count;
        }
        pattern.first = i;
        pattern.first_left = @max(pattern.value(i) - phase, 0);
        return pattern;
    }

    fn value(pattern: *const Pattern, i: usize) f32 {
        return pattern.values[i % pattern.values.len];
    }
};

/// Cuts contours into dashes, for one stroke's pass over its path.
pub const Dasher = struct {
    pattern: Pattern,
    memory: Memory,
    /// The dash being made, and a closed contour's first, each with its
    /// points' smoothness: a point where a dash is cut is an end.
    dash: *List(P),
    dash_smooth: *List(bool),
    first: *List(P),
    first_smooth: *List(bool),
    cuts: u32 = 0,
    /// Something did not fit.
    failed: bool = false,
    /// The way the path goes where the dash handed on is (a unit
    /// length): a dash of no length is capped across it.
    along: P = .{ .x = 1, .y = 0 },
    /// The way the curve goes at the ends of the dash handed on.
    ends: stroke_.Ends = .{},

    /// One contour's dashes handed to `emit`.
    pub fn contour(d: *Dasher, points: []const P, smooth: []const bool, closed: bool, context: anytype, comptime emit: flatten.Emit(@TypeOf(context))) void {
        if (points.len == 0) return;
        const pattern = &d.pattern;
        var i = pattern.first;
        var left = pattern.first_left;
        var on = i % 2 == 0;
        // A closed contour's first dash is kept to be joined to its last.
        const hold = closed and on;
        var held = false;
        var cut = false;
        d.dash.clear();
        d.dash_smooth.clear();
        d.first.clear();
        d.first_smooth.clear();
        d.along = .{ .x = 1, .y = 0 };
        d.ends = .{};
        var first_along = d.along;
        // The way the curve goes where the dash being made began, and the
        // ends of a closed contour's first.
        var dash_head: ?P = null;
        var first_ends: stroke_.Ends = .{};
        if (on) {
            if (!d.add(points[0], smooth[0])) return;
            dash_head = stroke_.tangentAt(points, smooth, closed, 0, 0);
        }
        const segments = if (closed) points.len else points.len - 1;
        // The last line passed that has a length: a dash that ends where
        // the next begins ends the way it does.
        var arrived: ?usize = null;
        var k: usize = 0;
        while (k < segments) : (k += 1) {
            const a = points[k];
            const next = (k + 1) % points.len;
            const b = points[next];
            const length = @sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y));
            if (!(length > 0)) continue;
            defer arrived = k;
            d.along = .{ .x = (b.x - a.x) / length, .y = (b.y - a.y) / length };
            var pos: f32 = 0;
            while (length - pos > left) {
                pos += left;
                const t = pos / length;
                const q = P{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
                const way_here = stroke_.tangentAt(points, smooth, closed, k, t);
                if (on) {
                    if (!d.add(q, false)) return;
                    const way_in = if (pos == 0) if (arrived) |line| stroke_.tangentAt(points, smooth, closed, line, 1) else way_here else way_here;
                    d.ends = .{ .head = dash_head, .tail = way_in };
                    if (hold and !held) {
                        held = true;
                        first_along = d.along;
                        first_ends = d.ends;
                        if (!d.first.reserve(d.memory, d.dash.len) or !d.first_smooth.reserve(d.memory, d.dash.len)) return d.fail();
                        for (d.dash.items(), d.dash_smooth.items()) |p, inside| {
                            _ = d.first.append(d.memory, p);
                            _ = d.first_smooth.append(d.memory, inside);
                        }
                    } else emit(context, d.dash.items(), d.dash_smooth.items(), false);
                    d.dash.clear();
                    d.dash_smooth.clear();
                } else {
                    d.dash.clear();
                    d.dash_smooth.clear();
                    if (!d.add(q, false)) return;
                    dash_head = way_here;
                }
                cut = true;
                d.cuts += 1;
                if (d.cuts >= max_cuts) {
                    // Past the most: on as it is now.
                    left = @import("std").math.inf(f32);
                    on = !on;
                    break;
                }
                i = (i + 1) % pattern.count;
                left = pattern.value(i);
                on = !on;
            }
            if (left != @import("std").math.inf(f32)) left -= length - pos;
            if (on and !d.add(b, smooth[next])) return;
        }
        if (!cut) {
            d.ends = .{};
            if (on) emit(context, points, smooth, closed);
            return;
        }
        if (on) {
            d.ends = .{
                .head = dash_head,
                .tail = if (held) first_ends.tail else stroke_.tangentAt(points, smooth, closed, segments - 1, 1),
            };
            if (held) {
                const rest = d.first.items();
                const rest_smooth = d.first_smooth.items();
                if (rest.len > 1) {
                    if (!d.dash.reserve(d.memory, rest.len - 1) or !d.dash_smooth.reserve(d.memory, rest.len - 1)) return d.fail();
                    for (rest[1..], rest_smooth[1..]) |p, inside| {
                        _ = d.dash.append(d.memory, p);
                        _ = d.dash_smooth.append(d.memory, inside);
                    }
                }
            }
            emit(context, d.dash.items(), d.dash_smooth.items(), false);
        } else if (held) {
            d.along = first_along;
            d.ends = first_ends;
            emit(context, d.first.items(), d.first_smooth.items(), false);
        }
    }

    /// A point and its smoothness onto the dash, both or neither.
    fn add(d: *Dasher, p: P, inside: bool) bool {
        if (d.dash.reserve(d.memory, 1) and d.dash_smooth.reserve(d.memory, 1)) {
            _ = d.dash.append(d.memory, p);
            _ = d.dash_smooth.append(d.memory, inside);
            return true;
        }
        d.fail();
        return false;
    }

    fn fail(d: *Dasher) void {
        d.failed = true;
    }
};

// --- tests ---------------------------------------------------------------------

const testing = @import("std").testing;
const test_memory = memory_.test_memory;

const Seen = struct {
    dashes: u32 = 0,
    closed: u32 = 0,
    starts: [16]P = undefined,
    ends: [16]P = undefined,
    mismatched: bool = false,

    fn emit(seen: *Seen, points: []const P, smooth: []const bool, closed: bool) void {
        if (smooth.len != points.len) seen.mismatched = true;
        if (seen.dashes < 16) {
            seen.starts[seen.dashes] = points[0];
            seen.ends[seen.dashes] = points[points.len - 1];
        }
        seen.dashes += 1;
        if (closed) seen.closed += 1;
    }
};

fn cutUp(points: []const P, closed: bool, stroke: vector.Stroke) !Seen {
    var dash: List(P) = .{};
    defer dash.deinit(test_memory);
    var dash_smooth: List(bool) = .{};
    defer dash_smooth.deinit(test_memory);
    var first: List(P) = .{};
    defer first.deinit(test_memory);
    var first_smooth: List(bool) = .{};
    defer first_smooth.deinit(test_memory);
    var d = Dasher{ .pattern = Pattern.of(&stroke).?, .memory = test_memory, .dash = &dash, .dash_smooth = &dash_smooth, .first = &first, .first_smooth = &first_smooth };
    var seen: Seen = .{};
    const smooth = [_]bool{false} ** 8;
    d.contour(points, smooth[0..points.len], closed, &seen, Seen.emit);
    try testing.expect(!d.failed);
    try testing.expect(!seen.mismatched);
    return seen;
}

test "a line cut into dashes, from an offset, an odd count gone through twice" {
    const line = [_]P{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 10, .y = 0 } };
    const dashes = [_]f32{ 2, 1 };
    var seen = try cutUp(&line, false, .{ .dashes = &dashes, .dash_count = 2 });
    // 0-2, 3-5, 6-8, 9-10.
    try testing.expectEqual(@as(u32, 4), seen.dashes);
    try testing.expectEqual(P{ .x = 3, .y = 0 }, seen.starts[1]);
    try testing.expectEqual(P{ .x = 5, .y = 0 }, seen.ends[1]);
    try testing.expectEqual(P{ .x = 10, .y = 0 }, seen.ends[3]);
    // From 2.5 in: the gap's last half, then 0.5-2.5, ...
    seen = try cutUp(&line, false, .{ .dashes = &dashes, .dash_count = 2, .dash_offset = 2.5 });
    try testing.expectEqual(P{ .x = 0.5, .y = 0 }, seen.starts[0]);
    // 3 is a dash of 3, a gap of 3: 0-3, 6-9.
    const three = [_]f32{3};
    seen = try cutUp(&line, false, .{ .dashes = &three, .dash_count = 1 });
    try testing.expectEqual(@as(u32, 2), seen.dashes);
    try testing.expectEqual(P{ .x = 9, .y = 0 }, seen.ends[1]);
}

test "a closed contour's last dash is joined to its first, and one no dash ends on stays closed" {
    const square = [_]P{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } };
    // 40 round: dashes of 6 and gaps of 4 end where they began.
    const dashes = [_]f32{ 6, 4 };
    var seen = try cutUp(&square, true, .{ .dashes = &dashes, .dash_count = 2, .dash_offset = 3 });
    // Starting 3 into a dash: its rest, 0-3, joins the last, 37-40.
    try testing.expectEqual(@as(u32, 4), seen.dashes);
    try testing.expectEqual(P{ .x = 0, .y = 3 }, seen.starts[3]);
    try testing.expectEqual(P{ .x = 3, .y = 0 }, seen.ends[3]);
    // Dashes of no length, one a corner: the first where it begins.
    const dots = [_]f32{ 0, 10 };
    seen = try cutUp(&square, true, .{ .dashes = &dots, .dash_count = 2 });
    try testing.expectEqual(@as(u32, 4), seen.dashes);
    try testing.expectEqual(P{ .x = 0, .y = 0 }, seen.starts[3]);
    try testing.expectEqual(P{ .x = 10, .y = 0 }, seen.starts[0]);
    const long = [_]f32{ 100, 1 };
    seen = try cutUp(&square, true, .{ .dashes = &long, .dash_count = 2 });
    try testing.expectEqual(@as(u32, 1), seen.closed);
}

/// Each dash's ends checked against the circle round the origin its
/// points lie near: the way it goes there, across its radius.
const AcrossRadii = struct {
    dasher: *const Dasher,
    dashes: u32 = 0,
    worst: f32 = 0,

    fn emit(across: *AcrossRadii, points: []const P, _: []const bool, _: bool) void {
        across.dashes += 1;
        const ends = across.dasher.ends;
        for ([_]P{ points[0], points[points.len - 1] }, [_]?P{ ends.head, ends.tail }) |at, given| {
            const way = given orelse {
                across.worst = 1;
                continue;
            };
            const radius = @sqrt(at.x * at.x + at.y * at.y);
            const along = P{ .x = -at.y / radius, .y = at.x / radius };
            across.worst = @max(across.worst, @abs(way.x - along.x) + @abs(way.y - along.y));
        }
    }
};

test "a dash cut inside a curve goes the way the curve does at its ends" {
    // A circle of radius 20 in 24 lines, cut into dashes of 5.
    var circle: [24]P = undefined;
    var flags: [24]bool = undefined;
    for (&circle, &flags, 0..) |*p, *f, i| {
        const angle = @as(f32, @floatFromInt(i)) / 24 * 2 * @import("std").math.pi;
        p.* = .{ .x = 20 * @cos(angle), .y = 20 * @sin(angle) };
        f.* = i % 6 != 0;
    }
    var dash: List(P) = .{};
    defer dash.deinit(test_memory);
    var dash_smooth: List(bool) = .{};
    defer dash_smooth.deinit(test_memory);
    var first: List(P) = .{};
    defer first.deinit(test_memory);
    var first_smooth: List(bool) = .{};
    defer first_smooth.deinit(test_memory);
    const dashes = [_]f32{ 5, 5 };
    const stroke = vector.Stroke{ .dashes = &dashes, .dash_count = 2, .dash_offset = 1 };
    var d = Dasher{ .pattern = Pattern.of(&stroke).?, .memory = test_memory, .dash = &dash, .dash_smooth = &dash_smooth, .first = &first, .first_smooth = &first_smooth };
    var across = AcrossRadii{ .dasher = &d };
    d.contour(&circle, &flags, true, &across, AcrossRadii.emit);
    try testing.expect(!d.failed);
    try testing.expect(across.dashes >= 12);
    try testing.expect(across.worst < 0.01);
}

test "lengths that are negative or come to nothing draw the stroke whole" {
    const negative = [_]f32{ 2, -1 };
    try testing.expect(Pattern.of(&.{ .dashes = &negative, .dash_count = 2 }) == null);
    const zero = [_]f32{ 0, 0 };
    try testing.expect(Pattern.of(&.{ .dashes = &zero, .dash_count = 2 }) == null);
    try testing.expect(Pattern.of(&.{}) == null);
}
