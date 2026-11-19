// SPDX-License-Identifier: MIT
//! AdjustColours: the pixels' colours changed in place - dehaze, colour
//! balance, brightness and contrast through a table a channel, then
//! saturation, hue and sepia as one 3 x 3 matrix in 16.16, then invert
//! through a table.

const sdk = @import("sdk");
const paintfx = sdk.paintfx;
const PaintFXBase = @import("../paintfx_base.zig").PaintFXBase;
const _pixels = @import("../pixels/_pixels.zig");

/// Changes the colours of pixels in place: haze, balance, brightness,
/// contrast, saturation, hue, sepia and inversion.
///
/// SYNOPSIS:
/// ```zig
/// fn AdjustColours(base: *PaintFXBase, pixels: *const paintfx.Pixels, adjust: *const paintfx.Adjust) void
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `pixels`: the pixels to change, `0xAARRGGBB`.
/// - `adjust`: the changes, each 0 for none; a value past its range is
///   taken as the end of the range.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Each pixel's red, green and blue go through the changes in the order
/// of `paintfx.Adjust`'s fields; its alpha stays as it is.
///
/// - `dehaze`: the level that the darkest of the three channels stays
///   above in all but a hundredth of the pixels that show (alpha 128 and
///   more) is the haze; that share of it is taken away from every
///   channel, and what is left stretched to the whole range again.
/// - `red`, `green`, `blue`: towards full by that share of what is
///   missing, or towards none by that share of what is there.
/// - `brightness`: up to 128 added or taken away.
/// - `contrast`: the distance from the middle, 128, multiplied - by 0 at
///   -100, by about 130 at 100.
/// - `saturation`, `hue`, `sepia`: one matrix on the three channels -
///   the colour moved from its grey (by the weights 0.213, 0.715 and
///   0.072) by 0 to 2 times, turned round that grey by whole degrees,
///   and mixed with its sepia tone.
/// - `invert`: towards the opposite, 255 less the channel.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not from an interrupt.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pixels stay the caller's.
///
/// NOTES:
/// The haze is measured on these pixels each time, so a view of part of
/// a picture lifts the haze of that part.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BlurPixels`, `SharpenPixels`
///
/// EXAMPLES:
/// ```zig
/// const view = paintfx.Pixels{ .pixels = pixels, .width = 640, .height = 480, .pitch = 640 };
/// fx.AdjustColours(&view, &.{ .brightness = 20, .saturation = -100 });
/// ```
pub fn AdjustColours(_: *PaintFXBase, pixels: *const paintfx.Pixels, adjust: *const paintfx.Adjust) void {
    if (!_pixels.usable(pixels)) return;
    const haze: i32 = if (adjust.dehaze == 0) 0 else @divTrunc(hazeOf(pixels) * @as(i32, @intCast(@min(adjust.dehaze, 100))), 100);
    var tables: [3][256]u8 = undefined;
    for (&tables, [3]i32{ adjust.red, adjust.green, adjust.blue }) |*table, balance| {
        for (table, 0..) |*entry, level| entry.* = @intCast(tone(@intCast(level), haze, balance, adjust.brightness, adjust.contrast));
    }
    var inverted: [256]u8 = undefined;
    const invert: u32 = @min(adjust.invert, 100);
    for (&inverted, 0..) |*entry, level| {
        const from: u32 = @intCast(level);
        entry.* = @intCast((from * (100 - invert) + (255 - from) * invert + 50) / 100);
    }
    const matrix = colourMatrix(adjust);
    var y: u32 = 0;
    while (y < pixels.height) : (y += 1) {
        for (_pixels.row(pixels, y)) |*pixel| {
            var red: u32 = tables[0][pixel.* >> 16 & 0xFF];
            var green: u32 = tables[1][pixel.* >> 8 & 0xFF];
            var blue: u32 = tables[2][pixel.* & 0xFF];
            if (matrix) |m| {
                const in = [3]i32{ @intCast(red), @intCast(green), @intCast(blue) };
                var out: [3]u32 = undefined;
                for (&out, m) |*channel, line| channel.* = _pixels.byte((line[0] * in[0] + line[1] * in[1] + line[2] * in[2] + half) >> 16);
                red = out[0];
                green = out[1];
                blue = out[2];
            }
            pixel.* = pixel.* & 0xFF000000 | @as(u32, inverted[red]) << 16 | @as(u32, inverted[green]) << 8 | inverted[blue];
        }
    }
}

const one: i32 = 1 << 16;
const half: i32 = 1 << 15;

/// The level `level` of one channel after the haze, its balance, the
/// brightness and the contrast.
fn tone(level: i32, haze: i32, balance: i32, brightness: i32, contrast: i32) u32 {
    var value = level;
    if (haze > 0) value = @divTrunc(@max(0, value - haze) * 255 + @divTrunc(255 - haze, 2), 255 - haze);
    const shift = @max(-100, @min(100, balance));
    if (shift > 0) value += @divTrunc((255 - value) * shift + 50, 100) else if (shift < 0) value += @divTrunc(value * shift - 50, 100);
    value += @divTrunc(@max(-100, @min(100, brightness)) * 128, 100);
    value = @max(0, @min(255, value));
    const steep = @max(-100, @min(100, contrast));
    if (steep != 0) {
        // The usual contrast curve: 259 (C + 255) / (255 (259 - C)), C
        // from -255 to 255, in 16.16.
        const c: i64 = @divTrunc(steep * 255, 100);
        const factor: i64 = @divTrunc(259 * (c + 255) * one, 255 * (259 - c));
        value = @intCast(@max(-1, @min(256, ((value - 128) * factor + half >> 16) + 128)));
    }
    return _pixels.byte(value);
}

/// The weights of red, green and blue in a colour's grey, in 16.16.
const grey = [3]i64{ 13959, 46858, 4719 };
/// What the hue's sine adds to the turn (with the cosine on the
/// colour's distance from its grey).
const turn = [3][3]i64{
    .{ -13959, -46858, 60817 },
    .{ 9372, 9175, -18547 },
    .{ -51577, 46858, 4719 },
};
/// A colour's sepia tone.
const sepia_tone = [3][3]i64{
    .{ 25756, 50397, 12386 },
    .{ 22872, 44958, 11010 },
    .{ 17826, 34996, 8585 },
};

/// Saturation, hue and sepia as one matrix, 16.16: sepia after the hue
/// after the saturation. Null when none of them changes anything.
fn colourMatrix(adjust: *const paintfx.Adjust) ?[3][3]i32 {
    const saturation = @max(-100, @min(100, adjust.saturation));
    const degrees: u32 = @intCast(@mod(@max(-180, @min(180, adjust.hue)), 360));
    const sepia: i64 = @min(adjust.sepia, 100);
    if (saturation == 0 and degrees == 0 and sepia == 0) return null;
    const strength: i64 = @divTrunc((100 + @as(i64, saturation)) * one, 100);
    const cos: i64 = sines[(degrees + 90) % 360];
    const sin: i64 = sines[degrees];
    const share: i64 = @divTrunc(sepia * one, 100);
    var saturate: [3][3]i64 = undefined;
    var hue: [3][3]i64 = undefined;
    var tint: [3][3]i64 = undefined;
    for (0..3) |i| {
        for (0..3) |j| {
            const own: i64 = if (i == j) one else 0;
            saturate[i][j] = grey[j] + (strength * (own - grey[j]) >> 16);
            hue[i][j] = grey[j] + (cos * (own - grey[j]) >> 16) + (sin * turn[i][j] >> 16);
            tint[i][j] = ((one - share) * own + share * sepia_tone[i][j]) >> 16;
        }
    }
    const both = times(hue, saturate);
    const all = times(tint, both);
    var made: [3][3]i32 = undefined;
    for (&made, all) |*line, from| {
        for (line, from) |*entry, value| entry.* = @intCast(value);
    }
    return made;
}

fn times(a: [3][3]i64, b: [3][3]i64) [3][3]i64 {
    var made: [3][3]i64 = undefined;
    for (0..3) |i| {
        for (0..3) |j| made[i][j] = (a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j] + half) >> 16;
    }
    return made;
}

/// The sines of whole degrees, times 65536, worked out as the library is
/// built.
const sines = table: {
    @setEvalBranchQuota(20000);
    var made: [360]i64 = undefined;
    for (&made, 0..) |*entry, degree| {
        const radians = @as(f64, @floatFromInt(degree)) * 3.14159265358979323846 / 180.0;
        entry.* = @intFromFloat(@round(@sin(radians) * 65536.0));
    }
    break :table made;
};

/// The haze: the level the darkest channel of the pixels that show stays
/// above in all but a hundredth of them.
fn hazeOf(pixels: *const paintfx.Pixels) i32 {
    var counts = [_]u32{0} ** 256;
    var total: u32 = 0;
    var y: u32 = 0;
    while (y < pixels.height) : (y += 1) {
        for (_pixels.row(pixels, y)) |pixel| {
            if (pixel >> 24 < 128) continue;
            const darkest = @min(pixel >> 16 & 0xFF, pixel >> 8 & 0xFF, pixel & 0xFF);
            counts[darkest] += 1;
            total += 1;
        }
    }
    if (total == 0) return 0;
    const below = total / 100;
    var seen: u32 = 0;
    for (counts, 0..) |count, level| {
        seen += count;
        // The haze never takes more than most of the range.
        if (seen > below) return @intCast(@min(level, 200));
    }
    return 0;
}
