// SPDX-License-Identifier: MIT
//! A property's value at a moment: a number, a point, a colour or a
//! path, still or moving between keyframes.
//!
//! A property is `{"a": 0|1, "k": ...}`. Its `k` is either the value
//! itself - a number, an array of numbers, a path - or an array of
//! keyframes, each `{"t": time, "s": start, "e": end, "o": ..., "i": ...,
//! "h": hold}`. Between two keyframes the value goes from the first's
//! start to its end (or, where it gives none, to the next one's start),
//! the way there given by a cubic Bezier from (0,0) to (1,1) whose two
//! inner points are the first keyframe's `o` and `i` - per dimension
//! when they are arrays. A held keyframe keeps its start until the next.
//! Before the first keyframe the value is the first's start, after the
//! last the last's.
//!
//! A position may also curve between its keyframes (`to`, `ti`): it
//! follows that cubic Bezier through space, the eased progress taken as
//! the curve's parameter.

const json = @import("json.zig");
const Tape = json.Tape;

/// Up to four numbers.
pub const Value = struct {
    v: [4]f32 = @splat(0),
    count: u32 = 0,

    pub fn of(values: []const f32) Value {
        var out = Value{ .count = @intCast(values.len) };
        for (values, 0..) |x, i| out.v[i] = x;
        return out;
    }

    pub fn at(numbers: Value, i: u32) f32 {
        if (numbers.count == 0) return 0;
        return numbers.v[@min(i, numbers.count - 1)];
    }
};

/// The numbers of a number or an array of them; empty when it is
/// neither.
pub fn vector(tape: Tape, index: ?u32) Value {
    const at = index orelse return .{};
    switch (tape.kind(at)) {
        .number => return Value.of(&.{tape.nodes[at].number}),
        .array => {
            var out = Value{};
            var walk = tape.items(at);
            while (walk.next()) |item| {
                if (out.count == 4) break;
                if (tape.kind(item) != .number) break;
                out.v[out.count] = tape.nodes[item].number;
                out.count += 1;
            }
            return out;
        },
        else => return .{},
    }
}

/// Whether `k` is an array of keyframes.
fn keyframed(tape: Tape, k: u32) bool {
    if (tape.kind(k) != .array or tape.count(k) == 0) return false;
    return tape.kind(k + 1) == .object;
}

/// Where between two keyframes a moment lies.
pub const Span = struct {
    /// The keyframe it starts from.
    from: u32,
    /// The keyframe it goes to, null when it stays at `from`'s value.
    to: ?u32 = null,
    /// How far, 0 to 1, before easing.
    progress: f32 = 0,
    /// Whether `from`'s end is wanted rather than its start: after the
    /// last keyframe of an older file, whose last has no start.
    use_end: bool = false,
};

/// The keyframes of `k` around time `t`.
pub fn span(tape: Tape, k: u32, t: f32) Span {
    const n = tape.count(k);
    var walk = tape.items(k);
    var previous: ?u32 = null;
    var index: u32 = 0;
    while (walk.next()) |frame| : (index += 1) {
        const time = tape.number(tape.get(frame, "t")) orelse 0;
        if (t < time) {
            const from = previous orelse return .{ .from = frame };
            const from_time = tape.number(tape.get(from, "t")) orelse 0;
            if (tape.flag(tape.get(from, "h")) or time <= from_time) return .{ .from = from };
            return .{ .from = from, .to = frame, .progress = (t - from_time) / (time - from_time) };
        }
        previous = frame;
    }
    // At or after the last: its start, or the end of the one before.
    const last = previous.?;
    if (tape.get(last, "s") == null and n >= 2) {
        return .{ .from = tape.item(k, n - 2).?, .use_end = true };
    }
    return .{ .from = last };
}

/// The cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1) at x.
pub fn ease(x: f32, x1: f32, y1: f32, x2: f32, y2: f32) f32 {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    if (x1 == y1 and x2 == y2) return x;
    // The parameter whose x is `x`, by halving: the curve's x always rises
    // when x1 and x2 lie in 0..1, as the format keeps them.
    var low: f32 = 0;
    var high: f32 = 1;
    var t: f32 = x;
    var step: u32 = 0;
    while (step < 24) : (step += 1) {
        const at_x = bezier(t, x1, x2);
        if (@abs(at_x - x) < 1e-5) break;
        if (at_x < x) low = t else high = t;
        t = (low + high) / 2;
    }
    return bezier(t, y1, y2);
}

/// One coordinate of the easing curve at parameter t.
fn bezier(t: f32, p1: f32, p2: f32) f32 {
    const u = 1 - t;
    return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t;
}

/// The eased progress of a span in dimension `d`.
pub fn eased(tape: Tape, s: Span, d: u32) f32 {
    if (s.to == null) return 0;
    const out = tape.get(s.from, "o");
    const in = tape.get(s.from, "i");
    if (out == null or in == null) return s.progress;
    const ox = vector(tape, tape.get(out, "x"));
    const oy = vector(tape, tape.get(out, "y"));
    const ix = vector(tape, tape.get(in, "x"));
    const iy = vector(tape, tape.get(in, "y"));
    if (ox.count == 0 or oy.count == 0 or ix.count == 0 or iy.count == 0) return s.progress;
    return ease(s.progress, ox.at(d), oy.at(d), ix.at(d), iy.at(d));
}

/// The start and end values of a span.
fn ends(tape: Tape, s: Span) struct { start: ?u32, end: ?u32 } {
    if (s.use_end) return .{ .start = tape.get(s.from, "e"), .end = null };
    const start = tape.get(s.from, "s");
    const to = s.to orelse return .{ .start = start, .end = null };
    return .{ .start = start, .end = tape.get(s.from, "e") orelse tape.get(to, "s") };
}

/// The value of property `prop` at time `t`; `default` when there is no
/// such property or it holds nothing.
pub fn value(tape: Tape, prop: ?u32, t: f32, default: Value) Value {
    const object = prop orelse return default;
    const k = tape.get(object, "k") orelse return default;
    if (!keyframed(tape, k)) {
        const still = vector(tape, k);
        return if (still.count == 0) default else still;
    }
    const s = span(tape, k, t);
    const range = ends(tape, s);
    const start = vector(tape, range.start);
    if (start.count == 0) return default;
    const end_index = range.end orelse return start;
    const end = vector(tape, end_index);
    if (end.count == 0) return start;

    // A position that curves through space.
    const to_tangent = vector(tape, tape.get(s.from, "to"));
    const ti_tangent = vector(tape, tape.get(s.from, "ti"));
    if (to_tangent.count >= 2 and ti_tangent.count >= 2 and start.count >= 2) {
        const p = eased(tape, s, 0);
        var out = start;
        for (0..@min(start.count, end.count, 3)) |i| {
            const d: u32 = @intCast(i);
            const p0 = start.v[i];
            const p3 = end.v[i];
            const p1 = p0 + to_tangent.at(d);
            const p2 = p3 + ti_tangent.at(d);
            const u = 1 - p;
            out.v[i] = u * u * u * p0 + 3 * u * u * p * p1 + 3 * u * p * p * p2 + p * p * p * p3;
        }
        return out;
    }

    var out = start;
    for (0..@min(start.count, end.count)) |i| {
        const p = eased(tape, s, @intCast(i));
        out.v[i] = start.v[i] + (end.v[i] - start.v[i]) * p;
    }
    return out;
}

/// A number property at `t`.
pub fn scalar(tape: Tape, prop: ?u32, t: f32, default: f32) f32 {
    return value(tape, prop, t, Value.of(&.{default})).v[0];
}

/// Where a path property stands at `t`: the shape (`{"c","v","i","o"}`)
/// it starts from, the one it goes to, and how far between.
pub const ShapeSpan = struct {
    from: u32,
    to: ?u32 = null,
    progress: f32 = 0,
};

/// The path of a path property at `t`, or null when it has none.
pub fn shape(tape: Tape, prop: ?u32, t: f32) ?ShapeSpan {
    const object = prop orelse return null;
    const k = tape.get(object, "k") orelse return null;
    if (!keyframed(tape, k)) return if (tape.kind(k) == .object) .{ .from = k } else null;
    const s = span(tape, k, t);
    const range = ends(tape, s);
    // A keyframe's shapes are arrays of one.
    const start = shapeIn(tape, range.start) orelse return null;
    const end = shapeIn(tape, range.end) orelse return .{ .from = start };
    return .{ .from = start, .to = end, .progress = eased(tape, s, 0) };
}

fn shapeIn(tape: Tape, index: ?u32) ?u32 {
    const at = index orelse return null;
    return switch (tape.kind(at)) {
        .object => at,
        .array => if (tape.count(at) > 0 and tape.kind(at + 1) == .object) at + 1 else null,
        else => null,
    };
}

const testing = @import("std").testing;

fn tapeOf(text: []const u8, nodes: []Node) Tape {
    const counted = json.parse(text, null).?;
    _ = json.parse(text, nodes[0..counted]).?;
    return .{ .text = text, .nodes = nodes[0..counted] };
}
const Node = json.Node;

test "still and keyframed values" {
    var nodes: [256]Node = undefined;
    const tape = tapeOf(
        \\{"still": {"a":0,"k":[10,20]},
        \\ "one": {"a":0,"k":7},
        \\ "moving": {"a":1,"k":[
        \\   {"t":0,"s":[0,100],"o":{"x":[0],"y":[0]},"i":{"x":[1],"y":[1]}},
        \\   {"t":10,"s":[100,0],"h":1},
        \\   {"t":20,"s":[50,50]}]}}
    , &nodes);
    const still = value(tape, tape.get(0, "still"), 3, .{});
    try testing.expectEqual(@as(u32, 2), still.count);
    try testing.expectEqual(@as(f32, 20), still.v[1]);
    try testing.expectEqual(@as(f32, 7), scalar(tape, tape.get(0, "one"), 0, 0));
    const moving = tape.get(0, "moving");
    try testing.expectEqual(@as(f32, 0), value(tape, moving, -5, .{}).v[0]);
    try testing.expectApproxEqAbs(@as(f32, 50), value(tape, moving, 5, .{}).v[0], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 50), value(tape, moving, 5, .{}).v[1], 0.01);
    // Held from 10 to 20.
    try testing.expectEqual(@as(f32, 100), value(tape, moving, 15, .{}).v[0]);
    try testing.expectEqual(@as(f32, 50), value(tape, moving, 25, .{}).v[0]);
    try testing.expectEqual(@as(f32, 3), scalar(tape, tape.get(0, "missing"), 0, 3));
}

test "easing" {
    try testing.expectApproxEqAbs(@as(f32, 0.5), ease(0.5, 0.25, 0.25, 0.75, 0.75), 1e-4);
    // Ease in and out: slow at the ends, half way at the middle.
    try testing.expect(ease(0.1, 0.42, 0, 0.58, 1) < 0.05);
    try testing.expectApproxEqAbs(@as(f32, 0.5), ease(0.5, 0.42, 0, 0.58, 1), 1e-3);
    try testing.expectEqual(@as(f32, 1), ease(1, 0.42, 0, 0.58, 1));
}
