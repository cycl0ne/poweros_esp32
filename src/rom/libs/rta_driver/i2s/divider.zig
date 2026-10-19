// SPDX-License-Identifier: MPL-2.0
//! The I2S controllers' fractional divider: how a source clock is divided
//! down to the master clock a codec counts in, worked out for every chip
//! the I2S line drives. Nothing here touches hardware, so the host tests
//! hold it.
//!
//! The controller divides by a whole number and a fraction. It counts the
//! fraction as a pattern rather than a ratio: of every `x + 1` periods of
//! the output, `z` are one source clock longer (or, with `yn1`, shorter),
//! with `y` left over. A fraction past a half is counted from the other
//! side, which keeps `z` small.

const std = @import("std");

/// A divider, in the fields the controller has.
pub const Divider = struct { whole: u32, x: u32, y: u32, z: u32, yn1: bool };

/// The divider that makes `want` out of `from`: a whole number and a
/// fraction, the fraction as the controller counts it - `z` clocks of one
/// length among `x + 1`, and `yn1` when the fraction is past a half.
pub fn divide(from: u32, want: u32) Divider {
    const whole = from / want;
    const rest = from - whole * want;
    if (rest == 0) return .{ .whole = whole, .x = 0, .y = 0, .z = 0, .yn1 = false };
    // The fraction is rest/want, in lowest terms.
    const common = gcd(rest, want);
    const numerator = rest / common;
    const denominator = want / common;
    const yn1 = numerator * 2 > denominator;
    const z = if (yn1) denominator - numerator else numerator;
    return .{
        .whole = whole,
        .x = denominator / z - 1,
        .y = denominator % z,
        .z = z,
        .yn1 = yn1,
    };
}

fn gcd(a: u32, b: u32) u32 {
    var x = a;
    var y = b;
    while (y != 0) {
        const t = y;
        y = x % y;
        x = t;
    }
    return x;
}

// --- tests --------------------------------------------------------------------------

const testing = std.testing;

test "12.288 MHz out of 160 MHz: 13 and 1/48" {
    const d = divide(160_000_000, 12_288_000);
    try testing.expectEqual(@as(u32, 13), d.whole);
    try testing.expectEqual(@as(u32, 1), d.z);
    try testing.expectEqual(@as(u32, 47), d.x);
    try testing.expectEqual(@as(u32, 0), d.y);
    try testing.expect(!d.yn1);
}

test "12.288 MHz out of the 40 MHz crystal: 3 and 49/192" {
    const d = divide(40_000_000, 12_288_000);
    try testing.expectEqual(@as(u32, 3), d.whole);
    try testing.expectEqual(@as(u32, 49), d.z);
    try testing.expectEqual(@as(u32, 2), d.x);
    try testing.expectEqual(@as(u32, 45), d.y);
    try testing.expect(!d.yn1);
    // Every field fits the controller's nine bits.
    try testing.expect(d.x < 512 and d.y < 512 and d.z < 512);
}

test "a fraction past a half is counted from the other side" {
    // 11/4 is 2 and 3/4: one short period among four.
    const d = divide(11, 4);
    try testing.expectEqual(@as(u32, 2), d.whole);
    try testing.expect(d.yn1);
    try testing.expectEqual(@as(u32, 1), d.z);
    try testing.expectEqual(@as(u32, 3), d.x);
}

test "a whole division has no fraction" {
    const d = divide(48_000_000, 12_000_000);
    try testing.expectEqual(@as(u32, 4), d.whole);
    try testing.expectEqual(@as(u32, 0), d.z);
    try testing.expect(!d.yn1);
}
