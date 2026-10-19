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

/// Whether the controllers can count a divider: a whole number of 2 to
/// 255, the fraction's fields in nine bits each.
///
/// INPUTS:
/// - `divider` - what `divide` worked out.
pub fn usable(divider: Divider) bool {
    return divider.whole >= 2 and divider.whole <= 255 and divider.x < 512 and divider.y < 512 and divider.z < 512;
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

test "11.2896 MHz, for 44.1 kHz: 14 and 76/441 out of 160 MHz, 3 and 479/882 out of 40 MHz" {
    const s3 = divide(160_000_000, 11_289_600);
    try testing.expectEqual(@as(u32, 14), s3.whole);
    try testing.expectEqual(@as(u32, 76), s3.z);
    try testing.expectEqual(@as(u32, 4), s3.x);
    try testing.expectEqual(@as(u32, 61), s3.y);
    try testing.expect(!s3.yn1);
    try testing.expect(usable(s3));
    // Past a half: 403 short periods counted instead of 479 long ones.
    const p4 = divide(40_000_000, 11_289_600);
    try testing.expectEqual(@as(u32, 3), p4.whole);
    try testing.expect(p4.yn1);
    try testing.expectEqual(@as(u32, 403), p4.z);
    try testing.expectEqual(@as(u32, 1), p4.x);
    try testing.expectEqual(@as(u32, 76), p4.y);
    try testing.expect(usable(p4));
}

test "a master clock the source is too slow for is no use" {
    // 96 kHz at 256 times: 24.576 MHz out of 40 MHz is a whole number of 1.
    try testing.expect(!usable(divide(40_000_000, 96_000 * 256)));
    try testing.expect(usable(divide(160_000_000, 96_000 * 256)));
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
