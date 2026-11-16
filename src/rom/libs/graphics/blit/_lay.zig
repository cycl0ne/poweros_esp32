// SPDX-License-Identifier: MPL-2.0
//! A picture laid over a rectangle of a surface, each pixel by its
//! coverage, by every core where there is enough of it
//! (`rows/_bands.zig`).
//!
//! **At full strength** each pixel counts by its own coverage, as
//! `blendRow` lays a row. **At less** (`alpha` below 255) the coverage
//! is taken times `alpha` / 256, so a picture fades as a whole and keeps
//! its soft edges. **A picture that covers fully** whatever its pixels'
//! top byte holds - a window's buffer, a format without coverage - is
//! laid at `alpha` alone.
//!
//! The sums are the ones a pen laid over takes (`Mix`), so a picture
//! looks the same whichever call laid it.
//!
//! A picture that lies in the rows it is laid over cannot be cut into
//! bands that run at once - a band would read what another has written -
//! and is laid a row after another.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const PixelFormat = rtg.bitmaps.PixelFormat;
const Rect = graphics.Rect;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const drawing = @import("../draw/_draw.zig");
const rows = @import("../rows/_rows.zig");
const bands = @import("../rows/_bands.zig");
const _blit = @import("_blit.zig");

/// Whether a format's pixels say how much each covers.
///
/// INPUTS:
/// - `format` - the picture's format.
pub fn covers(format: PixelFormat) bool {
    return switch (format) {
        .rgba32, .bgra32, .argb1555 => true,
        else => false,
    };
}

/// A picture's rows over a surface's.
const Lay = struct {
    /// The rectangle's first column in the surface's row 0.
    column: [*]u8,
    pitch: u32,
    format: PixelFormat,
    count: usize,
    /// The surface's row the picture's first row lands on.
    first: u32,
    /// The picture's pixel that lands on the rectangle's top left, and
    /// the bytes from one of its rows to the next.
    picture: [*]const u8,
    picture_pitch: u32,
    picture_format: PixelFormat,
    /// The strength it is laid at, 1 to 255.
    alpha: u32,
    /// Every pixel covers fully: laid at `alpha` alone.
    whole: bool,

    pub fn band(job: *const Lay, lo: u32, hi: u32) void {
        var y = lo;
        while (y < hi) : (y += 1) {
            const to = job.column + @as(usize, y) * job.pitch;
            const from = job.picture + @as(usize, y - job.first) * job.picture_pitch;
            if (job.alpha == 255 and !job.whole) {
                _blit.blendRow(to, job.format, from, job.picture_format, job.count);
            } else {
                strengthRow(to, job.format, from, job.picture_format, job.count, job.alpha, job.whole);
            }
        }
    }
};

/// A row of a picture laid over a row of a surface at a strength. The
/// pairs of formats pictures and displays use go with both formats known
/// and a whole pixel a load; any other pair a pixel at a time.
fn strengthRow(to: [*]u8, to_format: PixelFormat, from: [*]const u8, from_format: PixelFormat, count: usize, alpha: u32, whole: bool) void {
    inline for (.{ .bgra32, .rgb565 }) |dest| {
        inline for (.{ .rgba32, .bgra32 }) |source| {
            const D = if (dest == .bgra32) u32 else u16;
            if (to_format == dest and from_format == source and
                @intFromPtr(to) % @sizeOf(D) == 0 and @intFromPtr(from) % 4 == 0)
            {
                const out: [*]D = @ptrCast(@alignCast(to));
                const in: [*]const u32 = @ptrCast(@alignCast(from));
                return if (whole)
                    strengthRowAs(dest, source, out, in, count, alpha, true)
                else
                    strengthRowAs(dest, source, out, in, count, alpha, false);
            }
        }
    }
    const to_bytes = @max(rastport.formatBits(to_format) / 8, 1);
    const from_bytes = @max(rastport.formatBits(from_format) / 8, 1);
    for (0..count) |i| {
        const pen = rastport.unpackPen(from_format, rows.load(from + i * from_bytes, from_bytes));
        _blit.blendPixel(to + i * to_bytes, to_bytes, to_format, at(pen, alpha, whole));
    }
}

/// A picture's pixel with the coverage it lands at.
inline fn at(pen: graphics.Pen, alpha: u32, whole: bool) graphics.Pen {
    const coverage = if (whole) alpha else if (alpha == 255) pen >> 24 else (pen >> 24) * alpha >> 8;
    return (pen & 0x00FF_FFFF) | coverage << 24;
}

fn strengthRowAs(
    comptime dest: PixelFormat,
    comptime source: PixelFormat,
    to: [*]if (dest == .bgra32) u32 else u16,
    from: [*]const u32,
    count: usize,
    alpha: u32,
    comptime whole: bool,
) void {
    @setRuntimeSafety(false);
    for (to[0..count], from[0..count]) |*pixel, colour| {
        const pen = at(@call(.always_inline, rastport.unpackPen, .{ source, colour }), alpha, whole);
        const coverage = pen >> 24;
        if (coverage == 0) continue;
        const mixed = if (coverage == 0xFF) pen else drawing.Mix.of(pen).over(@call(.always_inline, rastport.unpackPen, .{ dest, pixel.* }));
        pixel.* = @truncate(@call(.always_inline, rastport.packPen, .{ dest, mixed }).?);
    }
}

/// A picture laid over a rectangle of a surface.
///
/// INPUTS:
/// - `gb` - the library, for exec's workers.
/// - `surface` - the surface, with pixels, in a format with colours.
/// - `on` - the rectangle, in the surface's own coordinates and inside it.
/// - `picture` - the picture's pixel that lands on the rectangle's top
///   left.
/// - `picture_pitch` - bytes from one of its rows to the next; 0 lays its
///   one row over every row.
/// - `picture_format` - its format, one with colours.
/// - `alpha` - the strength, 0 to 255.
/// - `whole` - whether every pixel covers fully whatever it says.
pub fn lay(gb: *GraphicsBase, surface: *const rtg.Surface, on: Rect, picture: [*]const u8, picture_pitch: u32, picture_format: PixelFormat, alpha: u32, whole: bool) void {
    if (on.isEmpty() or alpha == 0) return;
    const to_bytes = _blit.pixelBytes(surface);
    const from_bytes = @max(rastport.formatBits(picture_format) / 8, 1);
    const job = Lay{
        .column = surface.pixels.? + @as(usize, @intCast(on.min_x)) * to_bytes,
        .pitch = surface.pitch,
        .format = surface.format,
        .count = @intCast(on.width()),
        .first = @intCast(on.min_y),
        .picture = picture,
        .picture_pitch = picture_pitch,
        .picture_format = picture_format,
        .alpha = @min(alpha, 255),
        // At full strength each pixel counts by what it says itself,
        // which is all of it in a format without coverage.
        .whole = whole or (alpha < 255 and !covers(picture_format)),
    };
    // A picture in the rows it is laid over goes a row after another.
    const height: usize = @intCast(on.height());
    const picture_start = @intFromPtr(picture);
    const picture_end = picture_start + (height - 1) * picture_pitch + job.count * from_bytes;
    const dest_start = @intFromPtr(job.column) + @as(usize, job.first) * surface.pitch;
    const dest_end = dest_start + (height - 1) * surface.pitch + job.count * to_bytes;
    const apart = picture_end <= dest_start or dest_end <= picture_start;
    bands.share(gb.sys_base, Lay, &job, bands.Rows.of(job.first, @intCast(on.max_y), surface.pitch), if (apart) _blit.pixelsOf(on) else 0);
}

/// A colour laid over a rectangle of a surface by its alpha: nothing for
/// none, the colour itself for all of it.
///
/// INPUTS:
/// - `gb` - the library, for exec's workers.
/// - `surface` - the surface, with pixels, in a format with colours.
/// - `on` - the rectangle, in the surface's own coordinates and inside it.
/// - `pen` - the colour, 0xAARRGGBB.
pub fn tint(gb: *GraphicsBase, surface: *const rtg.Surface, on: Rect, pen: graphics.Pen) void {
    const alpha = pen >> 24;
    if (alpha == 0) return;
    const blend = alpha != 0xFF;
    drawing.fillRows(gb, .{
        .format = surface.format,
        .bytes = _blit.pixelBytes(surface),
        .lay = if (blend) .blend else .put,
        .packed_pen = rastport.packPen(surface.format, pen) orelse 0,
        .mix = if (blend) drawing.Mix.of(pen) else undefined,
    }, surface, on);
}

// --- tests (host: ./zig build test) -----------------------------------------
//
// Each row against the same laid a pixel at a time by `over`, in bands
// run one after another, the last first.

const std = @import("std");
const testing = std.testing;

/// A pixel laid over another as `over` lays it, each channel divided by
/// 255 and rounded: the sum written out, for the tests to hold `Mix` to.
fn slowOver(src: u32, dst: u32) u32 {
    const alpha = src >> 24;
    if (alpha == 0xFF) return src;
    if (alpha == 0) return dst;
    var mixed: u32 = 0xFF00_0000;
    var shift: u5 = 0;
    while (shift < 24) : (shift += 8) {
        mixed |= (((src >> shift & 0xFF) * alpha + (dst >> shift & 0xFF) * (255 - alpha) + 127) / 255) << shift;
    }
    return mixed;
}

test "a picture laid over: by each pixel's coverage, at a strength, whole, either way round" {
    const width = 40;
    const height = 20;
    const pitch = 64 * 4;
    var memory: [pitch * height]u8 align(64) = undefined;
    var before: [memory.len]u8 align(64) = undefined;
    var picture: [width * height]u32 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    const surface = rtg.Surface{ .pixels = &memory, .width = 64, .height = height, .pitch = pitch, .size_bytes = memory.len, .format = .bgra32 };

    for ([_]PixelFormat{ .bgra32, .rgba32 }) |format| {
        for ([_]u32{ 255, 128, 1 }) |alpha| {
            for ([_]bool{ false, true }) |whole| {
                prng.random().bytes(&memory);
                prng.random().bytes(std.mem.sliceAsBytes(&picture));
                // Some pixels that cover fully and some that cover nothing.
                for (0..width) |i| {
                    picture[i * 3] |= 0xFF00_0000;
                    picture[i * 5 + 1] &= 0x00FF_FFFF;
                }
                before = memory;
                const job = Lay{
                    .column = surface.pixels.? + 3 * 4,
                    .pitch = pitch,
                    .format = .bgra32,
                    .count = 31,
                    .first = 2,
                    .picture = @ptrCast(&picture[5 * width + 4]),
                    .picture_pitch = width * 4,
                    .picture_format = format,
                    .alpha = alpha,
                    .whole = whole,
                };
                const rows_of = bands.Rows.of(2, 17, pitch);
                var part: u32 = 3;
                while (part > 0) {
                    part -= 1;
                    const cut = rows_of.band(part, 3);
                    job.band(cut.lo, cut.hi);
                }
                for (0..height) |y| for (0..64) |x| {
                    const old = std.mem.readInt(u32, before[y * pitch + x * 4 ..][0..4], .little);
                    const now = std.mem.readInt(u32, memory[y * pitch + x * 4 ..][0..4], .little);
                    if (!(x >= 3 and x < 34 and y >= 2 and y < 17)) {
                        try testing.expectEqual(old, now);
                        continue;
                    }
                    const source = picture[(y - 2 + 5) * width + (x - 3 + 4)];
                    const pen = if (format == .rgba32) (source & 0xFF00_FF00) | (source >> 16 & 0xFF) | (source & 0xFF) << 16 else source;
                    const coverage = if (whole) alpha else if (alpha == 255) pen >> 24 else (pen >> 24) * alpha >> 8;
                    try testing.expectEqual(slowOver((pen & 0x00FF_FFFF) | coverage << 24, old), now);
                };
            }
        }
    }
}

test "a picture laid over a surface of another format takes the same sums a pixel at a time" {
    // rgb24 has no pair of its own: the row goes through `blendPixel`.
    var memory: [8 * 3]u8 = @splat(0x40);
    const picture = [8]u32{ 0xFF10_2030, 0x8010_2030, 0x0010_2030, 0xFFFF_FFFF, 0x01FF_FFFF, 0xFE00_0000, 0x7F80_8080, 0xFF00_00FF };
    strengthRow(&memory, .rgb24, @ptrCast(&picture), .bgra32, 8, 128, false);
    for (picture, 0..) |pen, i| {
        const coverage = (pen >> 24) * 128 >> 8;
        const expected = slowOver((pen & 0x00FF_FFFF) | coverage << 24, 0xFF40_4040);
        const now = rastport.unpackPen(.rgb24, rows.load(memory[i * 3 ..].ptr, 3));
        try testing.expectEqual(expected | 0xFF00_0000, now);
    }
}
