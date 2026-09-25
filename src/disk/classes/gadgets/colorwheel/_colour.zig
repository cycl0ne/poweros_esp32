// SPDX-License-Identifier: MIT
//! A colour wheel's arithmetic, in whole numbers: a colour between hue,
//! saturation and brightness and red, green and blue, a point on the
//! wheel to the hue and saturation there and back, and what that takes -
//! a quarter-degree sine table and a rounded square root.
//!
//! Components here count to 0xFFFF; the library's calls and the class's
//! attributes count to 0xFFFFFFFF, the same fraction in 32 bits
//! (`widen`, `narrow`).
//!
//! Hue goes clockwise from the top of the wheel, which is red; saturation
//! from nothing at the middle to all of it at the rim.

/// A colour with each component 0 to 0xFFFF.
pub const Hsb = struct { hue: u32 = 0, saturation: u32 = 0, brightness: u32 = 0 };
pub const Rgb = struct { red: u32 = 0, green: u32 = 0, blue: u32 = 0 };

/// All of a component, and one past it: a whole turn of hue.
pub const max_comp: i32 = 0xFFFF;
pub const max_range: i32 = 0x10000;

/// A 16-bit fraction in 32 bits, and back.
pub fn widen(value: u32) u32 {
    return (value << 16) | (value & 0xFFFF);
}

pub fn narrow(value: u32) u32 {
    return value >> 16;
}

// --- hue, saturation, brightness and red, green, blue -----------------------

/// How much hue each of the six sides of the colour hexagon takes.
const hue_side: u32 = 0xFFFF / 6 + 1;

pub fn hsbToRgb(hsb: Hsb) Rgb {
    if (hsb.saturation == 0) return .{ .red = hsb.brightness, .green = hsb.brightness, .blue = hsb.brightness };
    const v = hsb.brightness;
    const side = hsb.hue / hue_side;
    var f = (hsb.hue % hue_side) * 6;
    f += f >> 14;
    const p = hsb.brightness * (0xFFFF - hsb.saturation) >> 16;
    const q = hsb.brightness * (0xFFFF - (hsb.saturation * f >> 16)) >> 16;
    const t = hsb.brightness * (0xFFFF - (hsb.saturation * (0xFFFF - f) >> 16)) >> 16;
    return switch (side) {
        0 => .{ .red = v, .green = t, .blue = p },
        1 => .{ .red = q, .green = v, .blue = p },
        2 => .{ .red = p, .green = v, .blue = t },
        3 => .{ .red = p, .green = q, .blue = v },
        4 => .{ .red = t, .green = p, .blue = v },
        else => .{ .red = v, .green = p, .blue = q },
    };
}

pub fn rgbToHsb(rgb: Rgb) Hsb {
    const max = @max(rgb.red, @max(rgb.green, rgb.blue));
    const min = @min(rgb.red, @min(rgb.green, rgb.blue));
    const diff = max - min;
    var hsb = Hsb{ .brightness = max, .saturation = if (max != 0) diff * 0xFFFF / max else 0 };
    if (hsb.saturation == 0) return hsb;
    const rc: i64 = (max - rgb.red) * 0xFFFF / diff;
    const gc: i64 = (max - rgb.green) * 0xFFFF / diff;
    const bc: i64 = (max - rgb.blue) * 0xFFFF / diff;
    var h: i64 = undefined;
    if (rgb.red == max) {
        h = bc - gc;
        if (h < 0) h += 6 * 0xFFFF;
    } else if (rgb.green == max) {
        h = 2 * 0xFFFF + rc - bc;
    } else {
        h = 4 * 0xFFFF + gc - rc;
    }
    hsb.hue = @intCast(@divTrunc(h, 6));
    return hsb;
}

// --- a point on the wheel ---------------------------------------------------

/// A quarter turn in 24 steps, the whole turn in 96, and a 97th to
/// interpolate past the last.
pub const sin_table_size: i32 = 96;
pub const sin_one: i32 = (1 << 15) - 1;
pub const sin_table = [97]i32{
    0,      2143,   4277,   6393,   8481,   10533,  12539,  14492,  16384,  18204,  19947,  21605,
    23170,  24636,  25996,  27245,  28377,  29388,  30273,  31028,  31650,  32137,  32487,  32697,
    32767,  32697,  32487,  32137,  31650,  31028,  30273,  29388,  28377,  27245,  25996,  24636,
    23170,  21605,  19947,  18204,  16384,  14492,  12539,  10533,  8481,   6393,   4277,   2143,
    0,      -2142,  -4276,  -6392,  -8480,  -10532, -12538, -14491, -16383, -18203, -19946, -21604,
    -23169, -24635, -25995, -27244, -28376, -29387, -30272, -31027, -31649, -32136, -32486, -32696,
    -32766, -32696, -32486, -32136, -31649, -31027, -30272, -29387, -28376, -27244, -25995, -24635,
    -23169, -21604, -19946, -18203, -16383, -14491, -12538, -10532, -8480,  -6392,  -4276,  -2142,
    0,
};

/// Division rounded to the nearest, halves away from nothing.
pub fn roundDiv(dividend: i32, divisor: i32) i32 {
    var adjust = @divTrunc(divisor, 2);
    if (dividend < 0) adjust = -adjust;
    return @divTrunc(dividend + adjust, divisor);
}

/// The whole number nearest the square root.
pub fn roundSqrt(value: u32) u32 {
    var root: u32 = 0;
    var bit: u32 = 1 << 30;
    var rest = value;
    while (bit > rest) bit >>= 2;
    while (bit != 0) : (bit >>= 2) {
        if (rest >= root + bit) {
            rest -= root + bit;
            root = (root >> 1) + bit;
        } else {
            root >>= 1;
        }
    }
    // `rest` is value - root²: past halfway to (root + 1)² when above root.
    return if (rest > root) root + 1 else root;
}

/// The hue and saturation at a point `x_offset`, `y_offset` from the
/// middle of a wheel `x_radius` by `y_radius`.
pub fn hueSatAt(x_offset: i32, y_offset_given: i32, x_radius: i32, y_radius: i32) struct { hue: u32, saturation: u32 } {
    const xoff = x_offset;
    // The height counted as the width is, so an ellipse is a circle.
    const yoff = roundDiv(y_offset_given * x_radius, @max(y_radius, 1));
    const d2: i64 = @as(i64, xoff) * xoff + @as(i64, yoff) * yoff;
    const r2: i64 = @as(i64, x_radius) * x_radius;
    const d: i32 = @intCast(roundSqrt(@intCast(@min(d2, 0x3FFFFFFF))));
    var sat: i32 = if (d2 >= r2) max_comp else roundDiv(d * max_comp, @max(x_radius, 1));
    if (sat > max_comp) sat = max_comp;

    var hue: i32 = undefined;
    if (xoff == 0) {
        hue = if (yoff >= 0) @divTrunc(max_range, 4) else 3 * @divTrunc(max_range, 4);
    } else {
        // An arcsine from the table, as a cosine in the octants where that
        // is the steadier of the two.
        const axoff: i32 = @intCast(@abs(xoff));
        const ayoff: i32 = @intCast(@abs(yoff));
        const as_cos = ayoff > axoff;
        const s: i32 = @divTrunc((if (as_cos) axoff else ayoff) * sin_one, @max(d, 1));
        var i: usize = 1;
        while (i <= @as(usize, @intCast(@divTrunc(sin_table_size, 4)))) : (i += 1) {
            if (s < sin_table[i]) break;
        }
        i -= 1;
        const s2 = sin_table[i];
        const t = @divTrunc((s - s2) * @divTrunc(max_range, 4), @max(sin_table[i + 1] - s2, 1));
        hue = @divTrunc(@divTrunc(max_range, 4) * @as(i32, @intCast(i)) + t, @divTrunc(sin_table_size, 4));
        if (as_cos) hue = @divTrunc(max_range, 4) - hue;
        if (xoff < 0) hue = @divTrunc(max_range, 2) - hue;
        if (yoff < 0) hue = max_range - hue;
    }
    // A quarter turn round: red is at the top.
    hue += @divTrunc(max_range, 4);
    return .{ .hue = @intCast(hue & 0xFFFF), .saturation = @intCast(sat) };
}

/// Where the dot for a hue and saturation is, from the middle of a wheel
/// `x_radius` by `y_radius`.
pub fn dotAt(hue_given: u32, saturation: u32, x_radius: i32, y_radius: i32) struct { x: i32, y: i32 } {
    const hue: i32 = @intCast((hue_given -% @as(u32, @intCast(@divTrunc(max_comp, 4)))) & 0xFFFF);
    // The hue as sine-table steps, with sixty-fourths of a step kept to
    // interpolate with.
    const i: i32 = @intCast(@divTrunc(@as(i64, hue) * sin_table_size * 64, max_comp + 1));
    var j: usize = @intCast(@divTrunc(i, 64));
    const frac = i & 63;
    var s = sin_table[j];
    s += @divTrunc((sin_table[j + 1] - s) * frac, 64);
    const ty = roundDiv(y_radius * @as(i32, @intCast(saturation)), max_comp);
    const y = roundDiv(ty * s, sin_one);
    j += @intCast(@divTrunc(sin_table_size, 4));
    if (j >= @as(usize, @intCast(sin_table_size))) j -= @intCast(sin_table_size);
    s = sin_table[j];
    s += @divTrunc((sin_table[j + 1] - s) * frac, 64);
    const tx = roundDiv(x_radius * @as(i32, @intCast(saturation)), max_comp);
    return .{ .x = roundDiv(tx * s, sin_one), .y = y };
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

test "hue, saturation and brightness to red, green and blue, and back" {
    // The six corners of the hexagon, full and bright.
    try testing.expectEqual(Rgb{ .red = 0xFFFF, .green = 0, .blue = 0 }, hsbToRgb(.{ .hue = 0, .saturation = 0xFFFF, .brightness = 0xFFFF }));
    try testing.expectEqual(@as(u32, 0xFFFF), hsbToRgb(.{ .hue = 2 * hue_side, .saturation = 0xFFFF, .brightness = 0xFFFF }).green);
    try testing.expectEqual(@as(u32, 0xFFFF), hsbToRgb(.{ .hue = 4 * hue_side, .saturation = 0xFFFF, .brightness = 0xFFFF }).blue);
    // No saturation is a grey of the brightness.
    try testing.expectEqual(Rgb{ .red = 0x8000, .green = 0x8000, .blue = 0x8000 }, hsbToRgb(.{ .hue = 1234, .saturation = 0, .brightness = 0x8000 }));
    // Back again, near enough for 16 bits.
    for ([_]Rgb{ .{ .red = 0xFFFF, .green = 0x8000, .blue = 0 }, .{ .red = 0x1000, .green = 0x4000, .blue = 0xC000 }, .{ .red = 0x3333, .green = 0x3333, .blue = 0x9999 } }) |rgb| {
        const again = hsbToRgb(rgbToHsb(rgb));
        try testing.expect(@abs(@as(i64, again.red) - rgb.red) <= 8);
        try testing.expect(@abs(@as(i64, again.green) - rgb.green) <= 8);
        try testing.expect(@abs(@as(i64, again.blue) - rgb.blue) <= 8);
    }
}

test "a rounded square root" {
    try testing.expectEqual(@as(u32, 0), roundSqrt(0));
    try testing.expectEqual(@as(u32, 3), roundSqrt(9));
    try testing.expectEqual(@as(u32, 3), roundSqrt(12)); // 3.46
    try testing.expectEqual(@as(u32, 4), roundSqrt(13)); // 3.61
    try testing.expectEqual(@as(u32, 1000), roundSqrt(1000000));
}

test "a point to its hue and saturation, and the dot back to the point" {
    // Red at the top, going round clockwise: yellow-green to the right,
    // cyan at the bottom, blue-magenta to the left.
    try testing.expectEqual(@as(u32, 0), hueSatAt(0, -50, 50, 50).hue);
    try testing.expectEqual(@as(u32, 0x4000), hueSatAt(50, 0, 50, 50).hue);
    try testing.expectEqual(@as(u32, 0x8000), hueSatAt(0, 50, 50, 50).hue);
    try testing.expectEqual(@as(u32, 0xC000), hueSatAt(-50, 0, 50, 50).hue);
    // The middle is no saturation, the rim all of it and past it too.
    try testing.expectEqual(@as(u32, 0), hueSatAt(0, 0, 50, 50).saturation);
    try testing.expectEqual(@as(u32, 0xFFFF), hueSatAt(0, -50, 50, 50).saturation);
    try testing.expectEqual(@as(u32, 0xFFFF), hueSatAt(80, 80, 50, 50).saturation);
    // Round and back: the dot lands within a pixel of where it was put.
    for ([_][2]i32{ .{ 10, -20 }, .{ -30, 15 }, .{ 25, 25 }, .{ -5, -40 } }) |point| {
        const hs = hueSatAt(point[0], point[1], 50, 50);
        const dot = dotAt(hs.hue, hs.saturation, 50, 50);
        try testing.expect(@abs(dot.x - point[0]) <= 1);
        try testing.expect(@abs(dot.y - point[1]) <= 1);
    }
}
