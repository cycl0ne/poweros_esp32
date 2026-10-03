// SPDX-License-Identifier: MPL-2.0
//! The curves, in 16.16 fixed point: a progress from 0 to `one` in, where
//! the curve is out.
//!
//! Every curve is a polynomial or a few pieces of one, worked out with a
//! 64-bit product shifted back (`mul`), so nothing needs floating point.
//! Each starts at 0 and ends at exactly `one`: the end of an animation is
//! its end value, never one off it.
//!
//! The cubic Bezier is the curve with control points (x1, y1) and (x2, y2)
//! between (0, 0) and (1, 1). Its x is held to 0 to 1, so x grows with the
//! curve's own parameter; the parameter for a progress is found by halving
//! the interval to the last of 30 bits of fraction, and the y there,
//! rounded back to 16, is the answer.

const sdk = @import("sdk");
const motion = sdk.motion;

pub const one: i64 = motion.MOTION_ONE;

/// a times b, both 16.16.
fn mul(a: i64, b: i64) i64 {
    return (a * b) >> 16;
}

fn cube(t: i64) i64 {
    return mul(mul(t, t), t);
}

/// The overshoot's constants: how far past the end it goes (1.70158, the
/// usual 10 percent), and that plus one.
const back: i64 = 111514;
const back_plus: i64 = back + one;

/// The bounce: the parabola's steepness (7.5625) and the width (2.75) its
/// four arcs are counted in, as the fractions of the way they start at and
/// the heights they come down to.
const bounce_steep: i64 = 495616;
const arc_ends = [_]i64{ 23831, 47662, 59578 };
const arc_middles = [_]i64{ 35746, 53620, 62557 };
const arc_floors = [_]i64{ 49152, 61440, 64512 };

/// Where `curve` is at `progress`, both 16.16; a curve this does not know
/// is linear.
pub fn at(curve: u32, progress: u32) i32 {
    const t: i64 = @min(@as(i64, progress), one);
    if (t == one) return @intCast(one);
    if (t == 0) return 0;
    const value: i64 = switch (curve) {
        motion.EASE_IN => cube(t),
        motion.EASE_OUT => one - cube(one - t),
        motion.EASE_INOUT => if (t < one / 2) 4 * cube(t) else one - @divTrunc(cube(2 * one - 2 * t), 2),
        motion.EASE_OVERSHOOT => one + mul(back_plus, cube(t - one)) + mul(back, mul(t - one, t - one)),
        motion.EASE_BOUNCE => bounce(t),
        motion.EASE_STEP => 0,
        else => t,
    };
    return @intCast(value);
}

/// Four arcs, each lower than the last, the first from the start.
fn bounce(t: i64) i64 {
    if (t < arc_ends[0]) return mul(bounce_steep, mul(t, t));
    inline for (1..arc_ends.len) |i| {
        if (t < arc_ends[i]) {
            const from = t - arc_middles[i - 1];
            return mul(bounce_steep, mul(from, from)) + arc_floors[i - 1];
        }
    }
    const from = t - arc_middles[2];
    return mul(bounce_steep, mul(from, from)) + arc_floors[2];
}

/// The Bezier is worked out with 30 bits of fraction rather than 16, and
/// rounded once at the end: in 16 the truncations of its products add up
/// to several units in the middle of the curve.
const fine_shift = 14;
const fine_one: i64 = one << fine_shift;

fn fineMul(a: i64, b: i64) i64 {
    return (a * b) >> 30;
}

/// One coordinate of the Bezier at parameter `s`: 3(1-s)^2 s p1 +
/// 3(1-s) s^2 p2 + s^3, every value with 30 bits of fraction.
fn coordinate(p1: i64, p2: i64, s: i64) i64 {
    const rest = fine_one - s;
    return 3 * fineMul(fineMul(fineMul(rest, rest), s), p1) + 3 * fineMul(fineMul(fineMul(rest, s), s), p2) + fineMul(fineMul(s, s), s);
}

/// The Bezier with control points (x1, y1), (x2, y2) at `progress`, all
/// 16.16.
pub fn bezier(x1: i32, y1: i32, x2: i32, y2: i32, progress: u32) i32 {
    const t: i64 = @min(@as(i64, progress), one);
    if (t == one) return @intCast(one);
    if (t == 0) return 0;
    const cx1: i64 = @max(@min(@as(i64, x1), one), 0) << fine_shift;
    const cx2: i64 = @max(@min(@as(i64, x2), one), 0) << fine_shift;
    const target = t << fine_shift;
    var low: i64 = 0;
    var high: i64 = fine_one;
    var step: u32 = 0;
    while (step < 31) : (step += 1) {
        const middle = (low + high) >> 1;
        if (coordinate(cx1, cx2, middle) < target) low = middle else high = middle;
    }
    const s = (low + high) >> 1;
    const fine = coordinate(@as(i64, y1) << fine_shift, @as(i64, y2) << fine_shift, s);
    return @intCast((fine + (1 << (fine_shift - 1))) >> fine_shift);
}
