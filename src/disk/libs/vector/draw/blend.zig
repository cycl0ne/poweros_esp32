// SPDX-License-Identifier: MIT
//! Blend modes and the two colour spaces: how a colour goes onto the one
//! under it in each of CSS's blend modes, and a colour turned from sRGB
//! into linear light and back. Since 1.5.
//!
//! **A blend** mixes the colour laid down (the source) with the one under
//! it (the backdrop), both as they are, not premultiplied: `mix` is
//! CSS's B(Cb, Cs). Where only one of the two is, it stays as it is, so
//! the colour laid down is
//!
//!     (1 - ab) * Cs + ab * B(Cb, Cs)
//!
//! at the source's coverage over the backdrop - which `BLEND_NORMAL`,
//! whose B is the source itself, makes the plain `over`. The separable
//! modes mix each channel on its own; hue, saturation, colour and
//! luminosity mix the three together, by CSS's luminosity of
//! 0.3, 0.59, 0.11. `BLEND_PLUS_LIGHTER` is no mix but a sum, taken
//! apart by those that lay one down.
//!
//! **Porter and Duff's operators** (`BLEND_CLEAR` to `BLEND_XOR`) are no
//! mix either: the source and the backdrop, premultiplied, each times a
//! factor of the other's coverage, summed (`porterDuff`).
//!
//! **The colour spaces** are tables of 256 a way, made when the library
//! is built: sRGB's curve, and its inverse.

const sdk = @import("sdk");
const vector = sdk.vector;

/// CSS's B(Cb, Cs) in `mode`: the backdrop `under` and the source `over`,
/// each red, green and blue 0 to 1, not premultiplied.
pub fn mix(mode: u32, under: [3]f32, over: [3]f32) [3]f32 {
    return switch (mode) {
        vector.BLEND_HUE => setLum(setSat(over, sat(under)), lum(under)),
        vector.BLEND_SATURATION => setLum(setSat(under, sat(over)), lum(under)),
        vector.BLEND_COLOUR => setLum(over, lum(under)),
        vector.BLEND_LUMINOSITY => setLum(under, lum(over)),
        else => .{ separable(mode, under[0], over[0]), separable(mode, under[1], over[1]), separable(mode, under[2], over[2]) },
    };
}

/// One channel of a separable mode.
fn separable(mode: u32, cb: f32, cs: f32) f32 {
    return switch (mode) {
        vector.BLEND_MULTIPLY => cb * cs,
        vector.BLEND_SCREEN => cb + cs - cb * cs,
        vector.BLEND_OVERLAY => hardLight(cs, cb),
        vector.BLEND_DARKEN => @min(cb, cs),
        vector.BLEND_LIGHTEN => @max(cb, cs),
        vector.BLEND_COLOUR_DODGE => if (cb <= 0) 0 else if (cs >= 1) 1 else @min(1, cb / (1 - cs)),
        vector.BLEND_COLOUR_BURN => if (cb >= 1) 1 else if (cs <= 0) 0 else 1 - @min(1, (1 - cb) / cs),
        vector.BLEND_HARD_LIGHT => hardLight(cb, cs),
        vector.BLEND_SOFT_LIGHT => softLight(cb, cs),
        vector.BLEND_DIFFERENCE => @abs(cb - cs),
        vector.BLEND_EXCLUSION => cb + cs - 2 * cb * cs,
        else => cs,
    };
}

fn hardLight(cb: f32, cs: f32) f32 {
    if (cs <= 0.5) return cb * 2 * cs;
    const doubled = 2 * cs - 1;
    return cb + doubled - cb * doubled;
}

fn softLight(cb: f32, cs: f32) f32 {
    if (cs <= 0.5) return cb - (1 - 2 * cs) * cb * (1 - cb);
    const curve = if (cb <= 0.25) ((16 * cb - 12) * cb + 4) * cb else @sqrt(cb);
    return cb + (2 * cs - 1) * (curve - cb);
}

fn lum(colour: [3]f32) f32 {
    return 0.3 * colour[0] + 0.59 * colour[1] + 0.11 * colour[2];
}

fn clipColour(colour: [3]f32) [3]f32 {
    const luminance = lum(colour);
    const least = @min(colour[0], @min(colour[1], colour[2]));
    const most = @max(colour[0], @max(colour[1], colour[2]));
    var out = colour;
    if (least < 0 and luminance - least != 0) {
        for (&out) |*channel| channel.* = luminance + (channel.* - luminance) * luminance / (luminance - least);
    }
    if (most > 1 and most - luminance != 0) {
        for (&out) |*channel| channel.* = luminance + (channel.* - luminance) * (1 - luminance) / (most - luminance);
    }
    return out;
}

fn setLum(colour: [3]f32, luminance: f32) [3]f32 {
    const difference = luminance - lum(colour);
    return clipColour(.{ colour[0] + difference, colour[1] + difference, colour[2] + difference });
}

fn sat(colour: [3]f32) f32 {
    return @max(colour[0], @max(colour[1], colour[2])) - @min(colour[0], @min(colour[1], colour[2]));
}

fn setSat(colour: [3]f32, saturation: f32) [3]f32 {
    // The largest, the middle and the smallest, by their places.
    var max: usize = 0;
    var min: usize = 0;
    for (1..3) |index| {
        if (colour[index] > colour[max]) max = index;
        if (colour[index] < colour[min]) min = index;
    }
    if (max == min) return .{ 0, 0, 0 };
    const mid = 3 - max - min;
    var out: [3]f32 = undefined;
    out[mid] = (colour[mid] - colour[min]) * saturation / (colour[max] - colour[min]);
    out[max] = saturation;
    out[min] = 0;
    return out;
}

/// A premultiplied colour - red, green, blue and alpha, 0 to 1 - laid
/// over another in `mode`, at the source's coverage as it is.
pub fn compose(mode: u32, under: [4]f32, over: [4]f32) [4]f32 {
    if (isPorterDuff(mode)) return porterDuff(mode, under, over);
    const as = over[3];
    const ab = under[3];
    if (mode == vector.BLEND_PLUS_LIGHTER) return .{
        @min(1, under[0] + over[0]),
        @min(1, under[1] + over[1]),
        @min(1, under[2] + over[2]),
        @min(1, ab + as),
    };
    const ao = as + ab - as * ab;
    if (mode == vector.BLEND_NORMAL or ab <= 0 or as <= 0) return .{
        over[0] + under[0] * (1 - as),
        over[1] + under[1] * (1 - as),
        over[2] + under[2] * (1 - as),
        ao,
    };
    const cb = [3]f32{ under[0] / ab, under[1] / ab, under[2] / ab };
    const cs = [3]f32{ over[0] / as, over[1] / as, over[2] / as };
    const mixed = mix(mode, cb, cs);
    var out: [4]f32 = undefined;
    for (0..3) |channel| {
        const value = over[channel] * (1 - ab) + under[channel] * (1 - as) + as * ab * @min(@max(mixed[channel], 0), 1);
        out[channel] = @min(@max(value, 0), ao);
    }
    out[3] = ao;
    return out;
}

/// Whether `mode` is one of Porter and Duff's operators.
pub fn isPorterDuff(mode: u32) bool {
    return mode >= vector.BLEND_CLEAR and mode <= vector.BLEND_XOR;
}

/// Whether Porter and Duff's operator `mode` clears the backdrop where
/// there is no source: those that keep only what is of both, or of the
/// source.
pub fn clearsUncovered(mode: u32) bool {
    return switch (mode) {
        vector.BLEND_CLEAR, vector.BLEND_COPY, vector.BLEND_SOURCE_IN, vector.BLEND_DESTINATION_IN, vector.BLEND_SOURCE_OUT, vector.BLEND_DESTINATION_ATOP => true,
        else => false,
    };
}

/// The premultiplied source `over` and backdrop `under` put together by
/// Porter and Duff's operator `mode`: each times its factor, summed.
pub fn porterDuff(mode: u32, under: [4]f32, over: [4]f32) [4]f32 {
    const as = over[3];
    const ab = under[3];
    const source: f32, const backdrop: f32 = switch (mode) {
        vector.BLEND_CLEAR => .{ 0, 0 },
        vector.BLEND_COPY => .{ 1, 0 },
        vector.BLEND_DESTINATION => .{ 0, 1 },
        vector.BLEND_DESTINATION_OVER => .{ 1 - ab, 1 },
        vector.BLEND_SOURCE_IN => .{ ab, 0 },
        vector.BLEND_DESTINATION_IN => .{ 0, as },
        vector.BLEND_SOURCE_OUT => .{ 1 - ab, 0 },
        vector.BLEND_DESTINATION_OUT => .{ 0, 1 - as },
        vector.BLEND_SOURCE_ATOP => .{ ab, 1 - as },
        vector.BLEND_DESTINATION_ATOP => .{ 1 - ab, as },
        vector.BLEND_XOR => .{ 1 - ab, 1 - as },
        else => .{ 1, 1 - as },
    };
    var out: [4]f32 = undefined;
    for (0..4) |channel| out[channel] = @min(@max(over[channel] * source + under[channel] * backdrop, 0), 1);
    return out;
}

// --- colour spaces --------------------------------------------------------------

/// A channel of 0 to 255 in sRGB, in linear light; and back.
pub const to_linear: [256]u8 = table(false);
pub const to_srgb: [256]u8 = table(true);

fn table(comptime back: bool) [256]u8 {
    @setEvalBranchQuota(1_000_000);
    var out: [256]u8 = undefined;
    for (&out, 0..) |*entry, index| {
        const level = @as(f64, @floatFromInt(index)) / 255;
        const turned = if (back) linearToSrgb(level) else srgbToLinear(level);
        entry.* = @intFromFloat(@min(@max(turned * 255 + 0.5, 0), 255));
    }
    return out;
}

/// sRGB's curve, both ways, for a channel 0 to 1: at run time too, for a
/// colour given in numbers.
pub fn srgbToLinear(level: anytype) @TypeOf(level) {
    if (level <= 0.04045) return level / 12.92;
    return pow(@TypeOf(level), (level + 0.055) / 1.055, 2.4);
}

pub fn linearToSrgb(level: anytype) @TypeOf(level) {
    if (level <= 0.0031308) return level * 12.92;
    return 1.055 * pow(@TypeOf(level), level, 1.0 / 2.4) - 0.055;
}

/// `x` to the power `y`, for `x` over 0; 0 for less.
pub fn pow(comptime T: type, x: T, y: T) T {
    if (!(x > 0)) return 0;
    return @exp(y * @log(x));
}

/// A colour of 0 to 1 a channel, in linear light.
pub fn linearColour(colour: vector.Colour) vector.Colour {
    return .{ .r = srgbToLinear(colour.r), .g = srgbToLinear(colour.g), .b = srgbToLinear(colour.b), .a = colour.a };
}

// --- tests ---------------------------------------------------------------------

const testing = @import("std").testing;

test "the separable modes at their corners, the non-separable keeping what they take" {
    const grey = [3]f32{ 0.5, 0.5, 0.5 };
    try testing.expectEqual([3]f32{ 0.25, 0.25, 0.25 }, mix(vector.BLEND_MULTIPLY, grey, grey));
    try testing.expectEqual([3]f32{ 0.75, 0.75, 0.75 }, mix(vector.BLEND_SCREEN, grey, grey));
    try testing.expectEqual([3]f32{ 0, 0, 0 }, mix(vector.BLEND_DIFFERENCE, grey, grey));
    try testing.expectEqual([3]f32{ 1, 0.5, 0 }, mix(vector.BLEND_NORMAL, grey, .{ 1, 0.5, 0 }));
    try testing.expectEqual(@as(f32, 1), separable(vector.BLEND_COLOUR_DODGE, 0.5, 1));
    try testing.expectEqual(@as(f32, 0), separable(vector.BLEND_COLOUR_BURN, 0.5, 0));
    // The luminosity of grey onto red: red's hue at grey's lightness.
    const lit = mix(vector.BLEND_LUMINOSITY, .{ 1, 0, 0 }, grey);
    try testing.expectApproxEqAbs(@as(f32, 0.5), lum(lit), 0.001);
    try testing.expect(lit[0] > lit[1] and lit[1] == lit[2]);
    // A grey's hue onto anything is grey, of the backdrop's luminosity.
    const hue = mix(vector.BLEND_HUE, .{ 0, 0, 1 }, grey);
    try testing.expectApproxEqAbs(hue[0], hue[1], 0.001);
}

test "compose: normal is over, a blend only where both are, plus-lighter sums" {
    const red = [4]f32{ 1, 0, 0, 1 };
    const half_blue = [4]f32{ 0, 0, 0.5, 0.5 };
    const over = compose(vector.BLEND_NORMAL, red, half_blue);
    try testing.expectApproxEqAbs(@as(f32, 0.5), over[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), over[2], 0.001);
    try testing.expectEqual(@as(f32, 1), over[3]);
    // Multiply onto nothing is the source as it is.
    try testing.expectEqual(half_blue, compose(vector.BLEND_MULTIPLY, .{ 0, 0, 0, 0 }, half_blue));
    // Multiply of white onto red: red.
    try testing.expectEqual(red, compose(vector.BLEND_MULTIPLY, red, .{ 1, 1, 1, 1 }));
    try testing.expectEqual([4]f32{ 1, 0, 0.5, 1 }, compose(vector.BLEND_PLUS_LIGHTER, red, half_blue));
}

test "Porter and Duff's operators: each part of the source and the backdrop by the other's coverage" {
    const red = [4]f32{ 1, 0, 0, 1 };
    const half_blue = [4]f32{ 0, 0, 0.5, 0.5 };
    try testing.expectEqual([4]f32{ 0, 0, 0, 0 }, compose(vector.BLEND_CLEAR, red, half_blue));
    try testing.expectEqual(half_blue, compose(vector.BLEND_COPY, red, half_blue));
    try testing.expectEqual(red, compose(vector.BLEND_DESTINATION, red, half_blue));
    // Over the other way: the backdrop is whole, so on top.
    try testing.expectEqual(red, compose(vector.BLEND_DESTINATION_OVER, red, half_blue));
    // In: the source where the backdrop is, which is everywhere.
    try testing.expectEqual(half_blue, compose(vector.BLEND_SOURCE_IN, red, half_blue));
    try testing.expectEqual([4]f32{ 0.5, 0, 0, 0.5 }, compose(vector.BLEND_DESTINATION_IN, red, half_blue));
    try testing.expectEqual([4]f32{ 0, 0, 0, 0 }, compose(vector.BLEND_SOURCE_OUT, red, half_blue));
    try testing.expectEqual([4]f32{ 0.5, 0, 0, 0.5 }, compose(vector.BLEND_DESTINATION_OUT, red, half_blue));
    try testing.expectEqual([4]f32{ 0.5, 0, 0.5, 1 }, compose(vector.BLEND_SOURCE_ATOP, red, half_blue));
    try testing.expectEqual([4]f32{ 0.5, 0, 0, 0.5 }, compose(vector.BLEND_DESTINATION_ATOP, red, half_blue));
    try testing.expectEqual([4]f32{ 0.5, 0, 0, 0.5 }, compose(vector.BLEND_XOR, red, half_blue));
    // Onto nothing: what is kept of the source alone.
    const none = [4]f32{ 0, 0, 0, 0 };
    try testing.expectEqual(none, compose(vector.BLEND_SOURCE_IN, none, half_blue));
    try testing.expectEqual(half_blue, compose(vector.BLEND_SOURCE_OUT, none, half_blue));
    try testing.expectEqual(half_blue, compose(vector.BLEND_XOR, none, half_blue));
    try testing.expect(clearsUncovered(vector.BLEND_SOURCE_IN) and !clearsUncovered(vector.BLEND_XOR));
}

test "the colour spaces: ends kept, the middle darker in linear light, and back again" {
    try testing.expectEqual(@as(u8, 0), to_linear[0]);
    try testing.expectEqual(@as(u8, 255), to_linear[255]);
    try testing.expectEqual(@as(u8, 55), to_linear[128]);
    try testing.expectEqual(@as(u8, 128), to_srgb[55]);
    try testing.expectApproxEqAbs(@as(f32, 0.2140), srgbToLinear(@as(f32, 0.5)), 0.001);
}
