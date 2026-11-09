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
//! lengths that are negative or come to nothing draw the stroke whole.
//! A stroke is cut at most `max_cuts` times; past that it goes on as the
//! dash or the gap it is in.

const sdk = @import("sdk");
const vector = sdk.vector;
const P = vector.Point;
const memory_ = @import("memory.zig");
const Memory = memory_.Memory;
const List = memory_.List;

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
        while (phase >= pattern.value(i) and guard < 2 * count) : (guard += 1) {
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
    /// The dash being made, and a closed contour's first.
    dash: *List(P),
    first: *List(P),
    cuts: u32 = 0,
    /// Something did not fit.
    failed: bool = false,

    /// One contour's dashes handed to `emit`.
    pub fn contour(d: *Dasher, points: []const P, closed: bool, context: anytype, comptime emit: fn (@TypeOf(context), []const P, bool) void) void {
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
        d.first.clear();
        if (on and !d.add(points[0])) return;
        const segments = if (closed) points.len else points.len - 1;
        var k: usize = 0;
        while (k < segments) : (k += 1) {
            const a = points[k];
            const b = points[(k + 1) % points.len];
            const length = @sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y));
            if (!(length > 0)) continue;
            var pos: f32 = 0;
            while (length - pos > left) {
                pos += left;
                const t = pos / length;
                const q = P{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
                if (on) {
                    if (!d.add(q)) return;
                    if (hold and !held) {
                        held = true;
                        if (!d.first.reserve(d.memory, d.dash.len)) return d.fail();
                        for (d.dash.items()) |p| _ = d.first.append(d.memory, p);
                    } else emit(context, d.dash.items(), false);
                    d.dash.clear();
                } else {
                    d.dash.clear();
                    if (!d.add(q)) return;
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
            if (on and !d.add(b)) return;
        }
        if (!cut) {
            if (on) emit(context, points, closed);
            return;
        }
        if (on) {
            if (held) {
                const rest = d.first.items();
                if (rest.len > 1) {
                    if (!d.dash.reserve(d.memory, rest.len - 1)) return d.fail();
                    for (rest[1..]) |p| _ = d.dash.append(d.memory, p);
                }
            }
            emit(context, d.dash.items(), false);
        } else if (held) emit(context, d.first.items(), false);
    }

    fn add(d: *Dasher, p: P) bool {
        if (d.dash.append(d.memory, p)) return true;
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

    fn emit(seen: *Seen, points: []const P, closed: bool) void {
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
    var first: List(P) = .{};
    defer first.deinit(test_memory);
    var d = Dasher{ .pattern = Pattern.of(&stroke).?, .memory = test_memory, .dash = &dash, .first = &first };
    var seen: Seen = .{};
    d.contour(points, closed, &seen, Seen.emit);
    try testing.expect(!d.failed);
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
    const long = [_]f32{ 100, 1 };
    seen = try cutUp(&square, true, .{ .dashes = &long, .dash_count = 2 });
    try testing.expectEqual(@as(u32, 1), seen.closed);
}

test "lengths that are negative or come to nothing draw the stroke whole" {
    const negative = [_]f32{ 2, -1 };
    try testing.expect(Pattern.of(&.{ .dashes = &negative, .dash_count = 2 }) == null);
    const zero = [_]f32{ 0, 0 };
    try testing.expect(Pattern.of(&.{ .dashes = &zero, .dash_count = 2 }) == null);
    try testing.expect(Pattern.of(&.{}) == null);
}
