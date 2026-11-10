// SPDX-License-Identifier: MIT
//! Gradients: where along a gradient each pixel is, and its colour there
//! from a ramp of 256 made once a fill. Since 1.1.
//!
//! A pixel's centre is taken back through the drawing's matrix and the
//! paint's own (SVG's `gradientTransform`) into the gradient's units.
//! There a linear gradient is how far along from (x1, y1) to (x2, y2) the
//! point lies, and a radial one which of the circles going from the focus
//! circle (fx, fy, fr) out to (cx, cy, r) it is on - the furthest, as SVG
//! 2 has it; a focus outside the circle makes a cone, and nothing is
//! painted beside it. Past either end the spread pads, reflects or
//! repeats.
//!
//! The stops' colours are mixed as they are, not premultiplied, as SVG
//! 1.1 mixes them. A stop's offset is held to 0 to 1 and to no less than
//! the one before.

const sdk = @import("sdk");
const vector = sdk.vector;
const Matrix = vector.Matrix;
const image = @import("image.zig");

/// A colour of the ramp: red, green and blue 0 to 255, alpha 0 to 1.
pub const Entry = struct { r: f32, g: f32, b: f32, a: f32 };
pub const Ramp = [256]Entry;

/// What a paint paints: nothing, one colour, a gradient, or an image
/// (since 1.4, `image.zig`).
pub const Kind = union(enum) {
    none,
    solid: vector.Colour,
    gradient: Sampler,
    image: image.Sampler,
};

/// What `paint` comes to drawn through `matrix`, as SVG has it: one stop
/// a colour, a gradient of no length or no radius its last stop's colour,
/// no stops nothing; an image of no pixels nothing.
pub fn kindOf(paint: *const vector.Paint, matrix: Matrix) Kind {
    if (paint.kind == vector.PAINT_IMAGE) return if (image.Sampler.of(paint, matrix)) |s| .{ .image = s } else .none;
    if (paint.kind != vector.PAINT_LINEAR and paint.kind != vector.PAINT_RADIAL) return .{ .solid = paint.colour };
    const stops = paint.stops orelse return .none;
    if (paint.stop_count == 0) return .none;
    const last = stops[paint.stop_count - 1].colour;
    if (paint.stop_count == 1) return .{ .solid = stops[0].colour };
    if (paint.kind == vector.PAINT_LINEAR) {
        if (paint.x1 == paint.x2 and paint.y1 == paint.y2) return .{ .solid = last };
    } else if (!(paint.r > 0)) return .{ .solid = last };
    const inverse = matrix.then(paint.matrix).invert() orelse return .none;
    return .{ .gradient = Sampler.of(paint, inverse) };
}

/// The paint's stops spread over 256 colours.
pub fn fillRamp(ramp: *Ramp, stops: []const vector.Stop) void {
    var low: usize = 0;
    var low_offset = offsetOf(stops[0], 0);
    var high: usize = 0;
    var high_offset = low_offset;
    for (ramp, 0..) |*entry, n| {
        const t = @as(f32, @floatFromInt(n)) / 255;
        while (high_offset < t and high + 1 < stops.len) {
            low = high;
            low_offset = high_offset;
            high += 1;
            high_offset = offsetOf(stops[high], high_offset);
        }
        const colour = if (t <= low_offset or high == low)
            stops[low].colour
        else if (t >= high_offset or high_offset == low_offset)
            stops[high].colour
        else
            mix(stops[low].colour, stops[high].colour, (t - low_offset) / (high_offset - low_offset));
        entry.* = .{
            .r = channel(colour.r) * 255,
            .g = channel(colour.g) * 255,
            .b = channel(colour.b) * 255,
            .a = channel(colour.a),
        };
    }
}

fn offsetOf(stop: vector.Stop, before: f32) f32 {
    return @max(channel(stop.offset), before);
}

fn channel(v: f32) f32 {
    return if (v > 0) @min(v, 1) else 0;
}

fn mix(a: vector.Colour, b: vector.Colour, t: f32) vector.Colour {
    return .{
        .r = a.r + (b.r - a.r) * t,
        .g = a.g + (b.g - a.g) * t,
        .b = a.b + (b.b - a.b) * t,
        .a = a.a + (b.a - a.a) * t,
    };
}

/// Where a pixel is along a gradient.
pub const Sampler = struct {
    radial: bool,
    spread: u32,
    /// Pixels into the gradient's units.
    inverse: Matrix,
    // A linear gradient: its start, its way, over its length squared.
    x1: f32 = 0,
    y1: f32 = 0,
    dx: f32 = 0,
    dy: f32 = 0,
    // A radial one: the focus circle, the way to the end circle and how
    // much the radius grows, and the equation's square term.
    fx: f32 = 0,
    fy: f32 = 0,
    fr: f32 = 0,
    cdx: f32 = 0,
    cdy: f32 = 0,
    dr: f32 = 0,
    a: f32 = 0,

    fn of(paint: *const vector.Paint, inverse: Matrix) Sampler {
        var s = Sampler{ .radial = paint.kind == vector.PAINT_RADIAL, .spread = paint.spread, .inverse = inverse };
        if (!s.radial) {
            const dx = paint.x2 - paint.x1;
            const dy = paint.y2 - paint.y1;
            const length2 = dx * dx + dy * dy;
            s.x1 = paint.x1;
            s.y1 = paint.y1;
            s.dx = dx / length2;
            s.dy = dy / length2;
        } else {
            s.fx = paint.fx;
            s.fy = paint.fy;
            s.fr = @max(paint.fr, 0);
            s.cdx = paint.cx - paint.fx;
            s.cdy = paint.cy - paint.fy;
            s.dr = paint.r - s.fr;
            s.a = s.cdx * s.cdx + s.cdy * s.cdy - s.dr * s.dr;
        }
        return s;
    }

    /// The ramp's entry for the pixel at (x, y), its centre taken; null
    /// where the gradient paints nothing.
    pub fn index(s: *const Sampler, x: u32, y: u32) ?u8 {
        const p = s.inverse.apply(.{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 });
        const t = (if (s.radial) s.circle(p.x, p.y) else (p.x - s.x1) * s.dx + (p.y - s.y1) * s.dy) orelse return null;
        if (t != t) return null;
        const spread: f32 = switch (s.spread) {
            vector.SPREAD_REPEAT => t - @floor(t),
            vector.SPREAD_REFLECT => reflect: {
                const m = t - 2 * @floor(t / 2);
                break :reflect if (m > 1) 2 - m else m;
            },
            else => @min(@max(t, 0), 1),
        };
        return @intFromFloat(@min(@max(spread * 255 + 0.5, 0), 255));
    }

    /// The furthest circle through (x, y), as how far it is from the
    /// focus circle to the end one; null for none.
    fn circle(s: *const Sampler, x: f32, y: f32) ?f32 {
        const px = x - s.fx;
        const py = y - s.fy;
        const b = px * s.cdx + py * s.cdy + s.fr * s.dr;
        const c = px * px + py * py - s.fr * s.fr;
        if (@abs(s.a) < 1e-9) {
            if (b == 0) return null;
            const t = c / (2 * b);
            return if (s.fr + t * s.dr >= 0) t else null;
        }
        const disc = b * b - s.a * c;
        if (disc < 0) return null;
        const root = @sqrt(disc);
        const t1 = (b + root) / s.a;
        const t2 = (b - root) / s.a;
        const high = @max(t1, t2);
        const low = @min(t1, t2);
        if (s.fr + high * s.dr >= 0) return high;
        if (s.fr + low * s.dr >= 0) return low;
        return null;
    }
};

// --- tests ---------------------------------------------------------------------

const testing = @import("std").testing;

const red = vector.Colour{ .r = 1 };
const blue = vector.Colour{ .b = 1 };

test "a ramp holds its ends past the first and last stops, and mixes between" {
    var ramp: Ramp = undefined;
    const stops = [_]vector.Stop{ .{ .offset = 0.25, .colour = red }, .{ .offset = 0.75, .colour = blue } };
    fillRamp(&ramp, &stops);
    try testing.expectEqual(@as(f32, 255), ramp[0].r);
    try testing.expectEqual(@as(f32, 255), ramp[60].r);
    try testing.expectEqual(@as(f32, 255), ramp[255].b);
    try testing.expectApproxEqAbs(@as(f32, 127.5), ramp[128].r, 1.5);
    // A stop before the one before it is moved up to it: a step.
    const step = [_]vector.Stop{ .{ .offset = 0.5, .colour = red }, .{ .offset = 0.2, .colour = blue } };
    fillRamp(&ramp, &step);
    try testing.expectEqual(@as(f32, 255), ramp[127].r);
    try testing.expectEqual(@as(f32, 255), ramp[128].b);
}

test "linear and radial, padded, reflected and repeated" {
    const stops = [_]vector.Stop{ .{ .offset = 0, .colour = red }, .{ .offset = 1, .colour = blue } };
    var paint = vector.Paint{ .kind = vector.PAINT_LINEAR, .stops = &stops, .stop_count = 2, .x1 = 0, .x2 = 10 };
    var s = kindOf(&paint, .{}).gradient;
    // Pixel 0's centre is a twentieth of the way along.
    try testing.expectEqual(@as(u8, 13), s.index(0, 0).?);
    try testing.expectEqual(@as(u8, 255), s.index(15, 3).?);
    paint.spread = vector.SPREAD_REPEAT;
    s = kindOf(&paint, .{}).gradient;
    try testing.expectEqual(@as(u8, 13), s.index(10, 0).?);
    paint.spread = vector.SPREAD_REFLECT;
    s = kindOf(&paint, .{}).gradient;
    try testing.expectEqual(@as(u8, 242), s.index(10, 0).?);
    // Drawn twice the size: half as far along.
    paint.spread = vector.SPREAD_PAD;
    s = kindOf(&paint, Matrix.scale(2, 2)).gradient;
    try testing.expectEqual(@as(u8, 134), s.index(10, 0).?);

    const round = vector.Paint{ .kind = vector.PAINT_RADIAL, .stops = &stops, .stop_count = 2, .cx = 10, .cy = 10, .r = 10, .fx = 10, .fy = 10 };
    s = kindOf(&round, .{}).gradient;
    try testing.expectEqual(@as(u8, 18), s.index(10, 10).?);
    try testing.expectEqual(@as(u8, 141), s.index(15, 10).?);
    try testing.expectEqual(@as(u8, 255), s.index(25, 10).?);
    // The focus off the centre: offset 0 there.
    var focused = round;
    focused.fx = 5;
    s = kindOf(&focused, .{}).gradient;
    try testing.expectEqual(@as(u8, 14), s.index(5, 9).?);
}

test "what SVG paints for stops of none, one, and a gradient of no length" {
    const one = [_]vector.Stop{.{ .offset = 0.5, .colour = red }};
    const two = [_]vector.Stop{ .{ .colour = red }, .{ .offset = 1, .colour = blue } };
    var paint = vector.Paint{ .kind = vector.PAINT_LINEAR, .stops = &one, .stop_count = 0 };
    try testing.expect(kindOf(&paint, .{}) == .none);
    paint.stop_count = 1;
    try testing.expectEqual(red, kindOf(&paint, .{}).solid);
    paint.stops = &two;
    paint.stop_count = 2;
    paint.x2 = 0;
    try testing.expectEqual(blue, kindOf(&paint, .{}).solid);
    // A matrix that flattens everything onto a line: nothing.
    paint.x2 = 1;
    try testing.expect(kindOf(&paint, Matrix.scale(1, 0)) == .none);
}
