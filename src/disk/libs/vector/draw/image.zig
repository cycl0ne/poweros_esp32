// SPDX-License-Identifier: MIT
//! Images as paint: where in the image each pixel is, and its colour
//! there. Since 1.4.
//!
//! A pixel's centre is taken back through the drawing's matrix and the
//! paint's own into the image's units, a pixel of it each, and the
//! colour read there between the four pixels round it (bilinear), each
//! premultiplied first so that a clear pixel's colour does not bleed
//! into its neighbours. A pixel that covers more than one of the image's
//! - an image drawn smaller than it is - is the mean of a grid of such
//! reads across it, as many as it covers each way up to `max_taps`, so
//! a large image drawn small is not a scatter of its pixels. Past the
//! image's edges the spread pads with its edge pixels, repeats it or
//! reflects it.

const sdk = @import("sdk");
const vector = sdk.vector;
const Matrix = vector.Matrix;
const Pen = sdk.graphics.Pen;

/// The most reads a pixel takes each way.
pub const max_taps = 8;

/// A colour read from an image: red, green and blue 0 to 255 times its
/// alpha, and its alpha 0 to 1.
pub const Read = struct { r: f32, g: f32, b: f32, a: f32 };

pub const Sampler = struct {
    pixels: [*]const Pen,
    width: u32,
    height: u32,
    /// Pens from one row to the next.
    stride: u32,
    spread: u32,
    /// Pixels into the image's units.
    inverse: Matrix,
    /// Reads a pixel takes across and down.
    taps_x: u32,
    taps_y: u32,

    /// The sampler for `paint` drawn through `matrix`; null for an image
    /// of no pixels or a matrix that flattens it.
    pub fn of(paint: *const vector.Paint, matrix: Matrix) ?Sampler {
        const pixels = paint.image orelse return null;
        if (paint.image_width == 0 or paint.image_height == 0) return null;
        if (paint.image_bytes_per_row < paint.image_width * 4) return null;
        const inverse = matrix.then(paint.matrix).invert() orelse return null;
        // How many of the image's pixels one of the canvas's spans, each
        // way: the inverse's columns' lengths.
        const across = @sqrt(inverse.a * inverse.a + inverse.b * inverse.b);
        const down = @sqrt(inverse.c * inverse.c + inverse.d * inverse.d);
        return .{
            .pixels = pixels,
            .width = paint.image_width,
            .height = paint.image_height,
            .stride = paint.image_bytes_per_row / 4,
            .spread = paint.spread,
            .inverse = inverse,
            .taps_x = taps(across),
            .taps_y = taps(down),
        };
    }

    fn taps(span: f32) u32 {
        if (!(span > 1)) return 1;
        return @intFromFloat(@min(@ceil(span), max_taps));
    }

    /// The colour at the pixel (x, y), its centre taken; null where it is
    /// clear.
    pub fn sample(s: *const Sampler, x: u32, y: u32) ?Read {
        const cx = @as(f32, @floatFromInt(x)) + 0.5;
        const cy = @as(f32, @floatFromInt(y)) + 0.5;
        var sum = Read{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const nx: f32 = @floatFromInt(s.taps_x);
        const ny: f32 = @floatFromInt(s.taps_y);
        var j: u32 = 0;
        while (j < s.taps_y) : (j += 1) {
            const oy = (@as(f32, @floatFromInt(j)) + 0.5) / ny - 0.5;
            var i: u32 = 0;
            while (i < s.taps_x) : (i += 1) {
                const ox = (@as(f32, @floatFromInt(i)) + 0.5) / nx - 0.5;
                const p = s.inverse.apply(.{ .x = cx + ox, .y = cy + oy });
                const one = s.bilinear(p.x, p.y) orelse continue;
                sum.r += one.r;
                sum.g += one.g;
                sum.b += one.b;
                sum.a += one.a;
            }
        }
        const k = 1 / (nx * ny);
        if (sum.a * k < 1.0 / 512.0) return null;
        return .{ .r = sum.r * k, .g = sum.g * k, .b = sum.b * k, .a = sum.a * k };
    }

    /// The image read at (u, v) in its units, between the four pixels
    /// whose centres are round it.
    fn bilinear(s: *const Sampler, u: f32, v: f32) ?Read {
        if (u != u or v != v) return null;
        const fu = u - 0.5;
        const fv = v - 0.5;
        // Far outside and padded, it is the edge; held in range for the
        // conversion either way.
        const limit: f32 = 1 << 24;
        const iu_f = @floor(@min(@max(fu, -limit), limit));
        const iv_f = @floor(@min(@max(fv, -limit), limit));
        const tu = fu - iu_f;
        const tv = fv - iv_f;
        const iu: i32 = @intFromFloat(iu_f);
        const iv: i32 = @intFromFloat(iv_f);
        const x0 = s.wrap(iu, s.width);
        const x1 = s.wrap(iu + 1, s.width);
        const y0 = s.wrap(iv, s.height);
        const y1 = s.wrap(iv + 1, s.height);
        const p00 = s.texel(x0, y0);
        const p10 = s.texel(x1, y0);
        const p01 = s.texel(x0, y1);
        const p11 = s.texel(x1, y1);
        const w00 = (1 - tu) * (1 - tv);
        const w10 = tu * (1 - tv);
        const w01 = (1 - tu) * tv;
        const w11 = tu * tv;
        return .{
            .r = p00.r * w00 + p10.r * w10 + p01.r * w01 + p11.r * w11,
            .g = p00.g * w00 + p10.g * w10 + p01.g * w01 + p11.g * w11,
            .b = p00.b * w00 + p10.b * w10 + p01.b * w01 + p11.b * w11,
            .a = p00.a * w00 + p10.a * w10 + p01.a * w01 + p11.a * w11,
        };
    }

    /// A column or row past the image's edge brought back into it.
    fn wrap(s: *const Sampler, i: i32, n: u32) u32 {
        const size: i32 = @intCast(n);
        return @intCast(switch (s.spread) {
            vector.SPREAD_REPEAT => @mod(i, size),
            vector.SPREAD_REFLECT => reflect: {
                const m = @mod(i, 2 * size);
                break :reflect if (m >= size) 2 * size - 1 - m else m;
            },
            else => @min(@max(i, 0), size - 1),
        });
    }

    fn texel(s: *const Sampler, x: u32, y: u32) Read {
        const pen = s.pixels[@as(usize, y) * s.stride + x];
        const a = @as(f32, @floatFromInt(pen >> 24)) / 255;
        return .{
            .r = @as(f32, @floatFromInt((pen >> 16) & 0xFF)) * a,
            .g = @as(f32, @floatFromInt((pen >> 8) & 0xFF)) * a,
            .b = @as(f32, @floatFromInt(pen & 0xFF)) * a,
            .a = a,
        };
    }
};

// --- tests ---------------------------------------------------------------------

const testing = @import("std").testing;

test "an image read at its pixels' centres, between them, past its edges, and drawn smaller" {
    // Two by two: red, green / blue, clear.
    const pens = [_]Pen{ 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0x00FFFFFF };
    var paint = vector.Paint{ .kind = vector.PAINT_IMAGE, .image = &pens, .image_width = 2, .image_height = 2, .image_bytes_per_row = 8 };
    var s = Sampler.of(&paint, .{}).?;
    try testing.expectEqual(@as(u32, 1), s.taps_x);
    const red = s.sample(0, 0).?;
    try testing.expectApproxEqAbs(@as(f32, 255), red.r, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1), red.a, 0.01);
    // The clear one is clear: its white does not count.
    try testing.expect(s.sample(1, 1) == null);
    // Halfway between red and green: half of each, and whole.
    const mid = s.bilinear(1, 0.5).?;
    try testing.expectApproxEqAbs(@as(f32, 127.5), mid.r, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 127.5), mid.g, 0.01);
    // Halfway between green and the clear one: green, half covered.
    const fading = s.bilinear(1.5, 1).?;
    try testing.expectApproxEqAbs(@as(f32, 0.5), fading.a, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 127.5), fading.g, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), fading.r, 0.01);
    // Padded: far to the left of red is red; repeated: two to the right
    // of red is red again; reflected: just left of it is red too.
    try testing.expectApproxEqAbs(@as(f32, 255), s.bilinear(-40, 0.5).?.r, 0.01);
    paint.spread = vector.SPREAD_REPEAT;
    s = Sampler.of(&paint, .{}).?;
    try testing.expectApproxEqAbs(@as(f32, 255), s.bilinear(2.5, 0.5).?.r, 0.01);
    paint.spread = vector.SPREAD_REFLECT;
    s = Sampler.of(&paint, .{}).?;
    try testing.expectEqual(@as(u32, 0), s.wrap(-1, 2));
    try testing.expectEqual(@as(u32, 1), s.wrap(2, 2));
    // Drawn at half its size: one pixel takes two reads each way, the
    // mean of the four - three colours over four, a quarter clear.
    paint.spread = vector.SPREAD_PAD;
    s = Sampler.of(&paint, Matrix.scale(0.5, 0.5)).?;
    try testing.expectEqual(@as(u32, 2), s.taps_y);
    const all = s.sample(0, 0).?;
    try testing.expectApproxEqAbs(@as(f32, 0.75), all.a, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 63.75), all.b, 0.01);
    // No pixels, or a matrix that flattens it: nothing.
    paint.image_width = 0;
    try testing.expect(Sampler.of(&paint, .{}) == null);
}
