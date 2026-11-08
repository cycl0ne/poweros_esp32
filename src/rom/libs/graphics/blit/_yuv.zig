// SPDX-License-Identifier: MPL-2.0
//! YUV pictures turned into colours: what WriteYUVPixelArray and
//! ScaleYUVPixelArray share.
//!
//! A video frame is a plane of brightness (Y) and the colour (Cb, Cr) at
//! half the size each way, 4:2:0, a byte a sample or two for a picture of
//! ten bits. Each pixel's colour comes from its Y and the Cb and Cr of
//! the two by two it is in, through the picture's matrix - BT.601's,
//! BT.709's or BT.2020's - and range, in 16-bit fixed point: a multiply
//! for the luma and four for the chroma, whose terms the two pixels of a
//! pair share. The chroma is taken to sit in the middle of its four
//! pixels, where JPEG and MPEG-1 put it; MPEG-2 and H.264 put it a
//! quarter of a pixel further left, which no one sees.
//!
//! A picture of high dynamic range - one whose `transfer` is PQ or HLG -
//! takes the long way after that: each channel's number becomes the light
//! it stands for, the film's range of light is mapped into the screen's
//! by BT.2390's curve, its primaries are moved to the screen's, and the
//! light is encoded again as an SDR film's numbers. It is seven table
//! reads and a dozen multiplies a pixel against two multiplies, so a
//! picture that says nothing of all this - every ordinary film - goes the
//! short way with nothing added to it.
//!
//! The work is a piece of the destination at a time, as the clip cuts it.
//! A piece of `share_least` pixels or more is cut into bands of rows, one
//! for each core (exec's ShareWork): a 1920 by 1080 frame is two million
//! pixels, more than one core turns into colours at a film's pace.

const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const PixelFormat = rtg.bitmaps.PixelFormat;
const Rect = graphics.Rect;
const Pen = graphics.Pen;
const ExecBase = sdk.interface.exec.ExecBase;
const _blit = @import("_blit.zig");
const Span = _blit.Span;
const rows = @import("../rows/_rows.zig");
const rastport = @import("../rastport/_rastport.zig");

/// How a picture's numbers stand for colours, in 65536ths: red, green and
/// blue are `luma` times (Y - `black`), and the chroma's share - Cb and
/// Cr each taken from their `middle` - times its factor for each. A
/// sample of ten bits has four times the numbers of one of eight, so each
/// depth has its own factors and the loops need know nothing of it.
pub const Colors = struct {
    luma: i32,
    /// The Y that is black: 16 of a byte, 64 of ten bits, 0 where the
    /// numbers take the whole range.
    black: i32,
    /// The Cb and Cr that are no colour at all: 128 of a byte, 512 of ten
    /// bits.
    middle: i32,
    cr_red: i32,
    cb_green: i32,
    cr_green: i32,
    cb_blue: i32,
    /// The tables a picture of high dynamic range goes through after the
    /// matrix; null for a film of the range a screen has anyway.
    tone: ?*const Tone = null,
};

/// A matrix's factors, from its weights for red (`kr`) and blue (`kb`):
/// R = Y + 2(1 - kr) Cr, B = Y + 2(1 - kb) Cb, and G what is left of Y
/// once those are taken out. Video's range stretches Y's 219 steps and
/// the chroma's 224 - four times each at ten bits - to the whole byte.
fn colorsOf(comptime kr: f64, comptime kb: f64, comptime full: bool, comptime bits: u8) Colors {
    const kg = 1.0 - kr - kb;
    const wider: f64 = @floatFromInt(@as(u32, 1) << (bits - 8));
    const most: f64 = @floatFromInt((@as(u32, 1) << bits) - 1);
    const luma: f64 = if (full) 255.0 / most else 255.0 / (219.0 * wider);
    const chroma: f64 = if (full) 255.0 / most else 255.0 / (224.0 * wider);
    const one = 65536.0;
    return .{
        .luma = @intFromFloat(@round(luma * one)),
        .black = if (full) 0 else @intFromFloat(16.0 * wider),
        .middle = @intFromFloat(128.0 * wider),
        .cr_red = @intFromFloat(@round(2.0 * (1.0 - kr) * chroma * one)),
        .cb_green = @intFromFloat(@round(2.0 * (1.0 - kb) * kb / kg * chroma * one)),
        .cr_green = @intFromFloat(@round(2.0 * (1.0 - kr) * kr / kg * chroma * one)),
        .cb_blue = @intFromFloat(@round(2.0 * (1.0 - kb) * chroma * one)),
    };
}

/// BT.601's, BT.709's and BT.2020's weights, each in video's range and
/// then the whole number, each of those at eight bits and at ten.
fn matrixColors(comptime kr: f64, comptime kb: f64) [4]Colors {
    return .{
        colorsOf(kr, kb, false, 8), colorsOf(kr, kb, false, 10),
        colorsOf(kr, kb, true, 8),  colorsOf(kr, kb, true, 10),
    };
}

const known = matrixColors(0.299, 0.114) ++ matrixColors(0.2126, 0.0722) ++ matrixColors(0.2627, 0.0593);

/// The factors for a picture's `matrix`, `range` and `depth`, with the
/// tables for its curve where it has one, or null for anything of the
/// three this library does not know.
pub fn colorsFor(matrix: u8, range: u8, depth: u8, tone: ?*const Tone) ?Colors {
    if (matrix > rtg.RTGYUV_BT2020 or range > rtg.RTGYUV_FULL) return null;
    const wide: usize = switch (depth) {
        8 => 0,
        10 => 1,
        else => return null,
    };
    var colors = known[@as(usize, matrix) * 4 + @as(usize, range) * 2 + wide];
    colors.tone = tone;
    return colors;
}

/// The chroma's share of a pair's colour, the rounding in it: what each
/// of the pair adds its own luma to.
const Chroma = struct {
    red: i32,
    green: i32,
    blue: i32,
};

// The sums of a pixel cannot overflow - a factor is below 2^18 and a
// sample's distance from its middle below 2^10 - so they wrap rather than
// being checked, which keeps a branch a sum out of the loop of every
// pixel.
inline fn chromaOf(c: Colors, cb: u16, cr: u16) Chroma {
    const u = @as(i32, cb) - c.middle;
    const v = @as(i32, cr) - c.middle;
    return .{
        .red = c.cr_red *% v +% 32768,
        .green = 32768 -% c.cb_green *% u -% c.cr_green *% v,
        .blue = c.cb_blue *% u +% 32768,
    };
}

/// A channel from 65536ths, held to a byte. Nearly every one is inside
/// already: the branch is taken at the edges of the colour space.
inline fn byte(value: i32) u32 {
    const whole = value >> 16;
    if (@as(u32, @bitCast(whole)) > 255) return if (whole < 0) 0 else 255;
    return @intCast(whole);
}

inline fn penOf(c: Colors, y: u16, chroma: Chroma) Pen {
    const l = c.luma *% (@as(i32, y) - c.black);
    const red = l +% chroma.red;
    const green = l +% chroma.green;
    const blue = l +% chroma.blue;
    if (c.tone) |t| return tonePen(t, red, green, blue);
    return 0xFF000000 | byte(red) << 16 | byte(green) << 8 | byte(blue);
}

/// The colour of one Y, Cb and Cr.
pub fn penFor(c: Colors, y: u16, cb: u16, cr: u16) Pen {
    return penOf(c, y, chromaOf(c, cb, cr));
}

/// A picture's planes, checked: where its luma and each chroma sample
/// are, and the factors for its colours.
pub const Planes = struct {
    y: [*]const u8,
    cb: [*]const u8,
    cr: [*]const u8,
    y_pitch: usize,
    c_pitch: usize,
    /// Samples from one Cb (or Cr) to the next across: two in NV12's
    /// plane of pairs, one in I420's planes.
    step: usize,
    /// Two bytes a sample rather than one: a picture of ten bits.
    wide: bool,
    colors: Colors,

    /// Sample `i` of a row, whatever the depth: the ten bits of a wide
    /// one, which is what the factors of a ten-bit picture are for.
    inline fn at(p: *const Planes, line: [*]const u8, i: usize) u16 {
        if (!p.wide) return line[i];
        const words: [*]const u16 = @ptrCast(@alignCast(line));
        return words[i] & 0x03FF;
    }

    /// The planes of `picture`, with `tone` where it is one of high
    /// dynamic range; null for a layout, a depth or colours this library
    /// does not know, an I420 picture with no Cr plane, or a picture of
    /// ten bits whose planes or pitches do not start on a word.
    pub fn of(picture: *const rtg.RtgYuv, tone: ?*const Tone) ?Planes {
        const colors = colorsFor(picture.matrix, picture.range, picture.depth, tone) orelse return null;
        const wide = picture.depth == 10;
        if (wide) {
            const odd = @intFromPtr(picture.y) | @intFromPtr(picture.cb) |
                @intFromPtr(picture.cr orelse picture.cb) | picture.y_pitch | picture.c_pitch;
            if (odd & 1 != 0) return null;
        }
        const pair: usize = if (wide) 2 else 1;
        return switch (picture.layout) {
            rtg.RTGYUV_NV12 => .{
                .y = picture.y,
                .cb = picture.cb,
                .cr = picture.cb + pair,
                .y_pitch = picture.y_pitch,
                .c_pitch = picture.c_pitch,
                .step = 2,
                .wide = wide,
                .colors = colors,
            },
            rtg.RTGYUV_I420 => .{
                .y = picture.y,
                .cb = picture.cb,
                .cr = picture.cr orelse return null,
                .y_pitch = picture.y_pitch,
                .c_pitch = picture.c_pitch,
                .step = 1,
                .wide = wide,
                .colors = colors,
            },
            else => null,
        };
    }
};

/// A piece of the destination, filled from the picture: where its first
/// pixel is in the surface, how far it reaches, and which of the
/// picture's pixels each of its own takes.
pub const Piece = struct {
    planes: *const Planes,
    /// The piece's top left pixel in the surface.
    to: [*]u8,
    to_pitch: usize,
    format: PixelFormat,
    width: u32,
    height: u32,
    how: How,
    /// `.straight`: the picture's pixel that lands on the piece's top
    /// left.
    from_x: i32 = 0,
    from_y: i32 = 0,
    /// `.nearest`, `.smooth`: where the piece's top left is in the
    /// destination, and the scale - the part of the picture taken and
    /// where all of it lands.
    x: i32 = 0,
    y: i32 = 0,
    src: Rect = .{},
    dest: Rect = .{},

    pub const How = enum { straight, nearest, smooth };
};

/// A piece with this many pixels or more is shared over the cores.
/// Handing out a band costs some microseconds and a pixel some
/// nanoseconds; a piece below this is done sooner alone.
pub const share_least: u64 = 16 * 1024;
/// The most bands a piece is cut into; ShareWork makes it as many as
/// there are cores.
const share_parts_max: u32 = 8;

/// Fills a piece of the destination from the picture, on several cores
/// when it is worth it.
pub fn put(sys: *ExecBase, piece: *const Piece) void {
    if (piece.width == 0 or piece.height == 0) return;
    if (@as(u64, piece.width) * piece.height < share_least or piece.height < 2) {
        bandOf(piece, 0, piece.height);
        return;
    }
    _ = sys.ShareWork(&band, @constCast(piece), @min(piece.height, share_parts_max));
}

/// One band of a piece shared out, ShareWork's: as many rows each.
fn band(data: ?*anyopaque, part: u32, parts: u32) callconv(.c) void {
    const piece: *const Piece = @ptrCast(@alignCast(data.?));
    const first = @as(u64, piece.height) * part / parts;
    const end = @as(u64, piece.height) * (part + 1) / parts;
    bandOf(piece, @intCast(first), @intCast(end));
}

/// Rows `first` up to `end` of a piece. The surface's format is known
/// when the code is built, so each pixel is one store - one word where a
/// four-byte format's rows are aligned for it.
fn bandOf(piece: *const Piece, first: u32, end: u32) void {
    if (piece.how == .smooth) return smoothRows(piece, first, end);
    switch (piece.format) {
        inline .bgra32, .rgba32 => |f| {
            if (@intFromPtr(piece.to) % 4 == 0 and piece.to_pitch % 4 == 0)
                rowsAs(f, true, piece, first, end)
            else
                rowsAs(f, false, piece, first, end);
        },
        inline .rgb24, .bgr24, .rgb565, .argb1555, .gray8 => |f| rowsAs(f, false, piece, first, end),
        else => {},
    }
}

/// The loops of every pixel run without the overflow and alignment checks
/// of the kernel's build, which cost them about as much again as the work
/// itself; the host's tests run the same loops with the checks on.
const checked = builtin.is_test;

inline fn putAs(comptime format: PixelFormat, comptime words: bool, to: [*]u8, i: usize, pen: Pen) void {
    const bytes = comptime @max(rtg.bitmaps.formatBits(format) / 8, 1);
    const value = @call(.always_inline, rastport.packPen, .{ format, pen }) orelse 0;
    if (words) {
        const word: [*]u32 = @ptrCast(@alignCast(to));
        word[i] = value;
    } else {
        rows.store(to + i * bytes, bytes, value);
    }
}

fn rowsAs(comptime format: PixelFormat, comptime words: bool, piece: *const Piece, first: u32, end: u32) void {
    const p = piece.planes;
    var row = first;
    while (row < end) : (row += 1) {
        const to = piece.to + row * piece.to_pitch;
        switch (piece.how) {
            .straight => straightRow(format, words, p, @intCast(piece.from_y + @as(i32, @intCast(row))), @intCast(piece.from_x), piece.width, to),
            .nearest => nearestRow(format, words, p, piece, piece.y + @as(i32, @intCast(row)), to),
            .smooth => unreachable,
        }
    }
}

/// A row of the picture as it is, from pixel `sx` of row `sy`: the pairs
/// that share a Cb and a Cr worked out together.
fn straightRow(comptime format: PixelFormat, comptime words: bool, p: *const Planes, sy: usize, sx: usize, count: usize, to: [*]u8) void {
    @setRuntimeSafety(checked);
    const c = p.colors;
    const step = p.step;
    const luma = p.y + sy * p.y_pitch;
    const line = (sy >> 1) * p.c_pitch;
    const cb = p.cb + line;
    const cr = p.cr + line;
    const end = sx + count;
    var x = sx;
    var i: usize = 0;
    // An odd first pixel shares its chroma with one that is not drawn.
    if (x & 1 != 0) {
        const k = (x >> 1) * step;
        putAs(format, words, to, i, penOf(c, p.at(luma, x), chromaOf(c, p.at(cb, k), p.at(cr, k))));
        x += 1;
        i += 1;
    }
    var k = (x >> 1) * step;
    while (x + 2 <= end) : ({
        x += 2;
        i += 2;
        k += step;
    }) {
        const chroma = chromaOf(c, p.at(cb, k), p.at(cr, k));
        putAs(format, words, to, i, penOf(c, p.at(luma, x), chroma));
        putAs(format, words, to, i + 1, penOf(c, p.at(luma, x + 1), chroma));
    }
    if (x < end) putAs(format, words, to, i, penOf(c, p.at(luma, x), chromaOf(c, p.at(cb, k), p.at(cr, k))));
}

/// `floor((start + k * step) / divisor)` for k = 0, 1, 2 and on, a
/// division at the start and none after: where each pixel of a scaled
/// row comes from, exactly as working each out by itself would put it.
const Walk = struct {
    at: i64,
    over: i64,
    whole: i64,
    part: i64,
    divisor: i64,

    fn init(start: i64, step: i64, divisor: i64) Walk {
        return .{
            .at = @divFloor(start, divisor),
            .over = @mod(start, divisor),
            .whole = @divFloor(step, divisor),
            .part = @mod(step, divisor),
            .divisor = divisor,
        };
    }

    inline fn next(w: *Walk) void {
        w.at += w.whole;
        w.over += w.part;
        if (w.over >= w.divisor) {
            w.at += 1;
            w.over -= w.divisor;
        }
    }
};

/// Destination row `y` of a scale, each pixel the nearest of the picture
/// - as ScalePixelArray takes it, from the left and top edges: pixel
/// `dest.min + k` takes `src.min + floor(k * src / dest)`.
fn nearestRow(comptime format: PixelFormat, comptime words: bool, p: *const Planes, piece: *const Piece, y: i32, to: [*]u8) void {
    @setRuntimeSafety(checked);
    const c = p.colors;
    const step = p.step;
    const src_w: i64 = piece.src.width();
    const dest_w: i64 = piece.dest.width();
    const sy: usize = @intCast(piece.src.min_y + @divTrunc((y - piece.dest.min_y) * piece.src.height(), piece.dest.height()));
    const luma = p.y + sy * p.y_pitch;
    const line = (sy >> 1) * p.c_pitch;
    const cb = p.cb + line;
    const cr = p.cr + line;
    var walk = Walk.init(@as(i64, piece.src.min_x) * dest_w + @as(i64, piece.x - piece.dest.min_x) * src_w, src_w, dest_w);
    // Pixels made wider take the same chroma several times running.
    var last: usize = std.math.maxInt(usize);
    var chroma: Chroma = undefined;
    for (0..piece.width) |i| {
        const sx: usize = @intCast(walk.at);
        const k = (sx >> 1) * step;
        if (k != last) {
            chroma = chromaOf(c, p.at(cb, k), p.at(cr, k));
            last = k;
        }
        putAs(format, words, to, i, penOf(c, p.at(luma, sx), chroma));
        walk.next();
    }
}

/// The stretches `_blit.spanOf` gives the pixels of a destination row one
/// after another, a division at the start and none after.
const SpanWalk = struct {
    walk: Walk,
    /// Made smaller: the stretch runs from where the walk is to where its
    /// next step is, from `start`. Otherwise it is a pixel wide round
    /// `start` plus where the walk is.
    shrinks: bool,
    start: i64,
    from: i64,

    /// From destination pixel `dest`, as `spanOf(dest, dest_start,
    /// dest_size, src_start, src_size)` would take it.
    fn init(dest: i32, dest_start: i32, dest_size: i32, src_start: i32, src_size: i32) SpanWalk {
        const k: i64 = dest - dest_start;
        const src: i64 = src_size;
        const size: i64 = dest_size;
        if (src_size <= dest_size) {
            return .{
                .walk = Walk.init((2 * k + 1) * src * 256, 2 * src * 256, 2 * size),
                .shrinks = false,
                .start = @as(i64, src_start) * 256 - 128,
                .from = 0,
            };
        }
        var w = SpanWalk{
            .walk = Walk.init(k * src * 256, src * 256, size),
            .shrinks = true,
            .start = @as(i64, src_start) * 256 - 128,
            .from = 0,
        };
        w.from = w.start + w.walk.at;
        w.walk.next();
        return w;
    }

    /// This pixel's stretch, and the walk on to the next.
    inline fn take(w: *SpanWalk) Span {
        if (w.shrinks) {
            const to = w.start + w.walk.at;
            const span = Span{ .from = w.from, .to = to };
            w.from = to;
            w.walk.next();
            return span;
        }
        const middle = w.start + w.walk.at;
        w.walk.next();
        return .{ .from = middle - 128, .to = middle + 128 };
    }
};

/// The stretch of the chroma a stretch of the luma takes along one axis:
/// a chroma pixel is two luma pixels wide and sits in their middle. One
/// narrower than a chroma pixel - the luma made no smaller than half - is
/// widened to one round its middle, which mixes the two chroma pixels
/// nearest it by how near each is.
fn chromaSpan(luma: Span) Span {
    var span = Span{ .from = @divFloor(luma.from - 128, 2), .to = @divFloor(luma.to - 128, 2) };
    if (span.to - span.from < 256) {
        const middle = @divFloor(span.from + span.to, 2);
        span = .{ .from = middle - 128, .to = middle + 128 };
    }
    return span;
}

/// The part of the chroma under the part `luma` of the luma.
fn chromaArea(luma: Rect) Rect {
    return .{
        .min_x = @divFloor(luma.min_x, 2),
        .min_y = @divFloor(luma.min_y, 2),
        .max_x = @divFloor(luma.max_x + 1, 2),
        .max_y = @divFloor(luma.max_y + 1, 2),
    };
}

/// The mean of a plane of bytes over `across` by `down`, each byte by how
/// much of it lies in the two, as `_blit.sampleOver` takes a picture's
/// pixels; nothing outside `area` is read or counted.
fn meanOver(p: *const Planes, plane: [*]const u8, pitch: usize, step: usize, area: Rect, across: Span, down: Span) u16 {
    @setRuntimeSafety(checked);
    const first_x = @max(across.first(), area.min_x);
    const last_x = @min(across.last(), area.max_x - 1);
    const first_y = @max(down.first(), area.min_y);
    const last_y = @min(down.last(), area.max_y - 1);
    var sum: u64 = 0;
    var total: u64 = 0;
    var y = first_y;
    while (y <= last_y) : (y += 1) {
        const weight_y = down.share(y);
        if (weight_y == 0) continue;
        const line = plane + @as(usize, @intCast(y)) * pitch;
        var row: u64 = 0;
        // (the samples of this row, one or two bytes each)
        var row_total: u64 = 0;
        var x = first_x;
        while (x <= last_x) : (x += 1) {
            const weight_x = across.share(x);
            row += @as(u64, p.at(line, @as(usize, @intCast(x)) * step)) * weight_x;
            row_total += weight_x;
        }
        sum += row * weight_y;
        total += row_total * weight_y;
    }
    if (total == 0) {
        const x: usize = @intCast(@min(@max(first_x, area.min_x), area.max_x - 1));
        const line = plane + @as(usize, @intCast(@min(@max(first_y, area.min_y), area.max_y - 1))) * pitch;
        return p.at(line, x * step);
    }
    return @intCast((sum + total / 2) / total);
}

/// `meanOver` of the Cb and the Cr together: they lie alike, so each
/// share is worked out once for the two.
fn meanOfPair(p: *const Planes, cb: [*]const u8, cr: [*]const u8, pitch: usize, step: usize, area: Rect, across: Span, down: Span) [2]u16 {
    @setRuntimeSafety(checked);
    const first_x = @max(across.first(), area.min_x);
    const last_x = @min(across.last(), area.max_x - 1);
    const first_y = @max(down.first(), area.min_y);
    const last_y = @min(down.last(), area.max_y - 1);
    var sums: [2]u64 = .{ 0, 0 };
    var total: u64 = 0;
    var y = first_y;
    while (y <= last_y) : (y += 1) {
        const weight_y = down.share(y);
        if (weight_y == 0) continue;
        const line = @as(usize, @intCast(y)) * pitch;
        var row: [2]u64 = .{ 0, 0 };
        var row_total: u64 = 0;
        var x = first_x;
        while (x <= last_x) : (x += 1) {
            const weight_x = across.share(x);
            const at = line + @as(usize, @intCast(x)) * step;
            row[0] += @as(u64, p.at(cb, at)) * weight_x;
            row[1] += @as(u64, p.at(cr, at)) * weight_x;
            row_total += weight_x;
        }
        sums[0] += row[0] * weight_y;
        sums[1] += row[1] * weight_y;
        total += row_total * weight_y;
    }
    if (total == 0) {
        const x: usize = @intCast(@min(@max(first_x, area.min_x), area.max_x - 1));
        const at = @as(usize, @intCast(@min(@max(first_y, area.min_y), area.max_y - 1))) * pitch + x * step;
        return .{ p.at(cb, at), p.at(cr, at) };
    }
    return .{ @intCast((sums[0] + total / 2) / total), @intCast((sums[1] + total / 2) / total) };
}

/// Rows `first` up to `end` of a smooth scale: each pixel's luma and
/// chroma the mean of what it covers where the picture is made smaller,
/// and mixed from the nearest where it is made larger - ScalePixelArray's
/// smooth way, taken plane by plane before the colour is worked out.
fn smoothRows(piece: *const Piece, first: u32, end: u32) void {
    const p = piece.planes;
    const c = p.colors;
    const to_bytes = @max(rtg.bitmaps.formatBits(piece.format) / 8, 1);
    const src = piece.src;
    const dest = piece.dest;
    const chroma_area = chromaArea(src);
    var row = first;
    while (row < end) : (row += 1) {
        const to = piece.to + row * piece.to_pitch;
        const y = piece.y + @as(i32, @intCast(row));
        const down = _blit.spanOf(y, dest.min_y, dest.height(), src.min_y, src.height());
        const chroma_down = chromaSpan(down);
        var spans = SpanWalk.init(piece.x, dest.min_x, dest.width(), src.min_x, src.width());
        for (0..piece.width) |i| {
            const across = spans.take();
            const luma = meanOver(p, p.y, p.y_pitch, 1, src, across, down);
            const chroma = meanOfPair(p, p.cb, p.cr, p.c_pitch, p.step, chroma_area, chromaSpan(across), chroma_down);
            const pen = penFor(c, luma, chroma[0], chroma[1]);
            rows.store(to + i * to_bytes, to_bytes, rastport.packPen(piece.format, pen) orelse 0);
        }
    }
}

// --- high dynamic range ------------------------------------------------------

/// The light a screen's white stands for, in candelas a square metre:
/// ITU-R BT.2408's reference white, what a face or a sheet of paper is in
/// a film made for high dynamic range. Every light below is kept in
/// 65536ths of it.
pub const display_white: f64 = 203.0;
/// The same, as a whole number, for the sums that are not comptime.
const white_nits: u64 = 203;

/// Whether this build knows the high dynamic range curves. They cost ten
/// kilobytes of tables in the ROM, and a machine of 32 bits has no
/// decoder that could hand out such a picture (the software codecs are on
/// the 64-bit disks alone), so it does without them.
pub const tone_able = @bitSizeOf(usize) >= 64;

/// SMPTE ST 2084's light for a code value of 0 to 1 - the curve of HDR10,
/// in which a number stands for an absolute light of up to 10000 candelas
/// a square metre, not a share of the screen's white.
fn pqNits(code: f64) f64 {
    const m1 = 0.1593017578125;
    const m2 = 78.84375;
    const c1 = 0.8359375;
    const c2 = 18.8515625;
    const c3 = 18.6875;
    const p = std.math.pow(f64, code, 1.0 / m2);
    const num = @max(p - c1, 0.0);
    const den = c2 - c3 * p;
    return 10000.0 * std.math.pow(f64, num / den, 1.0 / m1);
}

/// BT.2100's hybrid log-gamma: the scene's light for a code value, put
/// through the curve a 1000-candela display applies to it (the OOTF with
/// a system gamma of 1.2), which puts its reference white - three
/// quarters of the way up - at 203 candelas, where PQ's is.
fn hlgNits(code: f64) f64 {
    const a = 0.17883277;
    const b = 0.28466892;
    const c = 0.55991073;
    const scene = if (code <= 0.5) code * code / 3.0 else (@exp((code - c) / a) + b) / 12.0;
    return 1000.0 * std.math.pow(f64, scene, 1.2);
}

/// The steps a curve's table has for the whole of its range. A channel
/// comes out of the matrix in 65536ths of a byte's step, so its top ten
/// bits - 255 times 4 of them - are the index, and the table's step is a
/// quarter of a byte's: 1020 of them span the range, and the three
/// entries past that are the range's end again, for a channel that
/// overshoots.
const light_steps = 1020;
/// How many steps the gain is worked out at: every fourth index, mixed
/// between for the rest. The curve is smooth, so four steps apart is
/// nearer than a step of the colour it ends up as.
const gain_steps = 256;
/// How finely a light is turned back into a number: 2048 steps up to the
/// screen's white. The curve is steepest near black, where a step is
/// a fifth of the colour's own, so nothing is mixed between.
const enc_steps = 2048;

/// The light of each of the 1024 code values of a curve, in 65536ths of
/// the screen's white.
const Light = [1024]u32;

fn lightTable(comptime nits: fn (f64) f64) Light {
    @setEvalBranchQuota(200000);
    var table: Light = undefined;
    for (&table, 0..) |*one, i| {
        const code = @min(@as(f64, @floatFromInt(i)) / @as(f64, light_steps), 1.0);
        const value = @round(nits(code) * 65536.0 / display_white);
        one.* = @intFromFloat(@min(@max(value, 0.0), 4294967295.0));
    }
    return table;
}

const pq_light: Light = if (tone_able) lightTable(pqNits) else @splat(0);
const hlg_light: Light = if (tone_able) lightTable(hlgNits) else @splat(0);

/// A light back to a number, BT.709's curve out of a camera - which is
/// what an SDR film carries, so a film mapped into it is encoded as one.
const encode_table: [enc_steps + 1]u8 = if (tone_able) blk: {
    @setEvalBranchQuota(200000);
    var table: [enc_steps + 1]u8 = undefined;
    for (&table, 0..) |*one, i| {
        const l = @as(f64, @floatFromInt(i)) / @as(f64, enc_steps);
        const v = if (l < 0.018) 4.5 * l else 1.099 * std.math.pow(f64, l, 0.45) - 0.099;
        one.* = @intFromFloat(@round(@min(@max(v, 0.0), 1.0) * 255.0));
    }
    break :blk table;
} else @splat(0);

/// A 3 by 3 in 65536ths, row by row: red, green and blue of one set of
/// primaries in another's.
const Matrix3 = [9]i32;

fn matrixOf(comptime m: [9]f64) Matrix3 {
    var out: Matrix3 = undefined;
    for (&out, 0..) |*one, i| one.* = @intFromFloat(@round(m[i] * 65536.0));
    return out;
}

/// BT.2020's red, green and blue in BT.709's (both about D65).
const bt2020_to_709 = matrixOf(.{
    1.660491,  -0.587641, -0.072850,
    -0.124550, 1.132900,  -0.008350,
    -0.018151, -0.100579, 1.118730,
});
/// DCI-P3's (about D65) in BT.709's.
const p3_to_709 = matrixOf(.{
    1.224940,  -0.224940, 0.0,
    -0.042057, 1.042057,  0.0,
    -0.019638, -0.078636, 1.098273,
});

/// What a picture of high dynamic range is drawn through: the light each
/// of its code values stands for, how much of that light is kept once the
/// film's range is mapped into the screen's, and its primaries in the
/// screen's. Made for each picture put down (`toneFor`) and left on the
/// caller's stack - a kilobyte - so that two films on two tasks need no
/// lock between them.
pub const Tone = struct {
    light: *const Light,
    /// The gain at code value `4 k`, in 65536ths; 65536 below the knee,
    /// where the film and the screen agree.
    gain: [gain_steps + 1]u32,
    prim: ?*const Matrix3,
};

/// The code value a light stands for in PQ, in 65536ths of full scale:
/// the table read backwards, which is where BT.2390's curve is worked
/// out.
fn pqCodeOf(light: u32) i64 {
    if (light == 0) return 0;
    var low: usize = 0;
    var high: usize = pq_light.len - 1;
    if (light >= pq_light[high]) return 65536;
    // The largest code whose light is at or below this one.
    while (high - low > 1) {
        const middle = (low + high) / 2;
        if (pq_light[middle] <= light) low = middle else high = middle;
    }
    const below = pq_light[low];
    const above = pq_light[low + 1];
    const part: i64 = if (above > below) @divTrunc(@as(i64, light - below) * 65536, above - below) else 0;
    return @min(@divTrunc(@as(i64, @intCast(low)) * 65536 + part, light_steps), 65536);
}

/// The light of a PQ code value given in 65536ths of full scale, mixed
/// between the table's steps.
fn pqLightAt(code: i64) u32 {
    const at = @max(@min(code, 65536), 0) * light_steps;
    const i: usize = @intCast(at >> 16);
    if (i >= pq_light.len - 1) return pq_light[pq_light.len - 1];
    const part = at & 0xFFFF;
    const below: i64 = pq_light[i];
    const above: i64 = pq_light[i + 1];
    return @intCast(below + ((above - below) * part >> 16));
}

/// The tables for `picture`, or null where it is a picture of the range a
/// screen has anyway - the usual film, which goes down the short way.
/// `into` is the caller's room for them, which lasts as long as the call.
pub fn toneFor(picture: *const rtg.RtgYuv, into: *Tone) ?*const Tone {
    if (!tone_able) return null;
    into.light = switch (picture.transfer) {
        rtg.RTGYUV_PQ => &pq_light,
        rtg.RTGYUV_HLG => &hlg_light,
        else => return null,
    };
    into.prim = switch (picture.primaries) {
        rtg.RTGYUV_BT2020 => &bt2020_to_709,
        rtg.RTGYUV_P3 => &p3_to_709,
        else => null,
    };
    // HLG says nothing about the light it was made for; a thousand
    // candelas is what its curve is drawn for.
    const nits: u32 = if (picture.transfer == rtg.RTGYUV_PQ and picture.peak != 0)
        picture.peak
    else
        rtg.RTGYUV_PEAK_DEFAULT;
    fillGain(into, @min(nits, 10000));
    return into;
}

/// BT.2390's EETF: the light of the film mapped into the light of the
/// screen, worked out in PQ's code values, where the eye's steps are
/// even. Below the knee the film is left alone; from there to its peak a
/// Hermite curve bends it down to the screen's white, so that a highlight
/// keeps its order instead of being cut off.
///
/// The gain is on the light, taken from the largest of red, green and
/// blue rather than from the brightness: all three are then scaled alike,
/// which keeps the colour of a highlight where a curve run on each
/// channel by itself would wash it out, and cannot push a channel past
/// white the way a curve on brightness alone can.
fn fillGain(t: *Tone, peak_nits: u32) void {
    const one: i64 = 65536;
    const peak_light: u32 = @intCast(@divTrunc(@as(u64, peak_nits) * 65536, white_nits));
    const e_white = pqCodeOf(65536);
    const e_peak = pqCodeOf(peak_light);
    if (e_peak <= e_white or e_white == 0) {
        t.gain = @splat(65536);
        return;
    }
    const max_lum = @divTrunc(e_white * one, e_peak);
    const knee = @max(@divTrunc(3 * max_lum, 2) - @divTrunc(one, 2), 0);
    for (&t.gain, 0..) |*one_gain, k| {
        const code = @min(k * 4, pq_light.len - 1);
        const light = t.light[code];
        if (light == 0) {
            one_gain.* = 65536;
            continue;
        }
        const e1 = @min(@divTrunc(pqCodeOf(light) * one, e_peak), one);
        if (e1 <= knee) {
            one_gain.* = 65536;
            continue;
        }
        // P(e1), BT.2390-8 (5.4.1): the Hermite curve from the knee to the
        // film's peak, which lands on the screen's white.
        const span = one - knee;
        const x = @divTrunc((e1 - knee) * one, span);
        const x2 = x * x >> 16;
        const x3 = x2 * x >> 16;
        const p = ((2 * x3 - 3 * x2 + one) * knee >> 16) +
            ((x3 - 2 * x2 + x) * span >> 16) +
            ((3 * x2 - 2 * x3) * max_lum >> 16);
        const mapped = pqLightAt(@divTrunc(p * e_peak, one));
        one_gain.* = @intCast(@min(@divTrunc(@as(i64, mapped) * 65536, light), 65536));
    }
}

/// A channel out of the matrix - 65536ths of a byte's step - as the
/// index of the curve's table: its top ten bits.
inline fn code10(value: i32) usize {
    if (value <= 0) return 0;
    return @min(@as(usize, @intCast(value >> 14)), 1023);
}

/// A light back to a number for the screen, BT.709's curve.
inline fn encodeLight(light: i64) u32 {
    if (light <= 0) return 0;
    const at = light >> 5;
    return encode_table[@intCast(@min(at, enc_steps))];
}

inline fn mix(m: *const Matrix3, at: usize, r: i64, g: i64, b: i64) i64 {
    return (@as(i64, m[at]) * r + @as(i64, m[at + 1]) * g + @as(i64, m[at + 2]) * b) >> 16;
}

/// The colour of a pixel of high dynamic range: its three channels'
/// light, mapped into the screen's range together, moved to the screen's
/// primaries and encoded as an SDR film's numbers.
fn tonePen(t: *const Tone, red: i32, green: i32, blue: i32) Pen {
    const rc = code10(red);
    const gc = code10(green);
    const bc = code10(blue);
    var r: i64 = t.light[rc];
    var g: i64 = t.light[gc];
    var b: i64 = t.light[bc];
    const high = @max(rc, @max(gc, bc));
    const gain: i64 = blk: {
        const i = high >> 2;
        const part: i64 = @intCast(high & 3);
        const below: i64 = t.gain[i];
        const above: i64 = t.gain[i + 1];
        break :blk below + ((above - below) * part >> 2);
    };
    if (gain != 65536) {
        r = r * gain >> 16;
        g = g * gain >> 16;
        b = b * gain >> 16;
    }
    if (t.prim) |m| {
        const nr = mix(m, 0, r, g, b);
        const ng = mix(m, 3, r, g, b);
        const nb = mix(m, 6, r, g, b);
        r = nr;
        g = ng;
        b = nb;
    }
    return 0xFF000000 | encodeLight(r) << 16 | encodeLight(g) << 8 | encodeLight(b);
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "black, white and grey come out as themselves in every matrix and range" {
    for ([_]u8{ rtg.RTGYUV_BT601, rtg.RTGYUV_BT709, rtg.RTGYUV_BT2020 }) |matrix| {
        const video = colorsFor(matrix, rtg.RTGYUV_LIMITED, 8, null).?;
        try testing.expectEqual(graphics.penRGB(0, 0, 0), penFor(video, 16, 128, 128));
        try testing.expectEqual(graphics.penRGB(255, 255, 255), penFor(video, 235, 128, 128));
        try testing.expectEqual(graphics.penRGB(128, 128, 128), penFor(video, 126, 128, 128));
        // Below black and above white is held to them.
        try testing.expectEqual(graphics.penRGB(0, 0, 0), penFor(video, 0, 128, 128));
        try testing.expectEqual(graphics.penRGB(255, 255, 255), penFor(video, 255, 128, 128));

        const full = colorsFor(matrix, rtg.RTGYUV_FULL, 8, null).?;
        try testing.expectEqual(graphics.penRGB(0, 0, 0), penFor(full, 0, 128, 128));
        try testing.expectEqual(graphics.penRGB(255, 255, 255), penFor(full, 255, 128, 128));
        try testing.expectEqual(graphics.penRGB(77, 77, 77), penFor(full, 77, 128, 128));
    }
}

/// The Y, Cb and Cr of a colour, worked out the long way in floating
/// point - what an encoder does. `r`, `g` and `b` are 0 to 255 whatever
/// the depth, and the numbers come back at `bits` of it.
fn encodeAt(kr: f64, kb: f64, full: bool, comptime bits: u8, r: f64, g: f64, b: f64) [3]u16 {
    const y = kr * r + (1 - kr - kb) * g + kb * b;
    const pb = (b - y) / (2 * (1 - kb));
    const pr = (r - y) / (2 * (1 - kr));
    const wider: f64 = @floatFromInt(@as(u32, 1) << (bits - 8));
    const most: f64 = @floatFromInt((@as(u32, 1) << bits) - 1);
    const scale_y: f64 = if (full) most else 219 * wider;
    const scale_c: f64 = if (full) most else 224 * wider;
    const black: f64 = if (full) 0 else 16 * wider;
    // The whole byte's chroma reaches half a step past the top at the edge.
    return .{
        @intFromFloat(@round(black + y * scale_y / 255)),
        @intFromFloat(@min(@round(128 * wider + pb * scale_c / 255), most)),
        @intFromFloat(@min(@round(128 * wider + pr * scale_c / 255), most)),
    };
}

fn encode(kr: f64, kb: f64, full: bool, r: f64, g: f64, b: f64) [3]u16 {
    return encodeAt(kr, kb, full, 8, r, g, b);
}

test "the primaries and their mixes come back within a step of themselves" {
    const matrices = [_]struct { matrix: u8, kr: f64, kb: f64 }{
        .{ .matrix = rtg.RTGYUV_BT601, .kr = 0.299, .kb = 0.114 },
        .{ .matrix = rtg.RTGYUV_BT709, .kr = 0.2126, .kb = 0.0722 },
        .{ .matrix = rtg.RTGYUV_BT2020, .kr = 0.2627, .kb = 0.0593 },
    };
    const colours = [_][3]u8{
        .{ 255, 0, 0 },   .{ 0, 255, 0 },   .{ 0, 0, 255 },    .{ 255, 255, 0 },
        .{ 0, 255, 255 }, .{ 255, 0, 255 }, .{ 200, 100, 50 }, .{ 30, 160, 220 },
    };
    for (matrices) |m| {
        for ([_]bool{ false, true }) |full| {
            const c = colorsFor(m.matrix, if (full) rtg.RTGYUV_FULL else rtg.RTGYUV_LIMITED, 8, null).?;
            for (colours) |rgb| {
                const ycc = encode(m.kr, m.kb, full, @floatFromInt(rgb[0]), @floatFromInt(rgb[1]), @floatFromInt(rgb[2]));
                const pen = penFor(c, ycc[0], ycc[1], ycc[2]);
                // Video's range has fewer steps than a byte, so a colour
                // can come back two off; the whole byte keeps it to one.
                const most: i32 = if (full) 2 else 3;
                for (0..3) |i| {
                    const got: i32 = @intCast(pen >> @intCast(16 - i * 8) & 0xFF);
                    try testing.expect(@abs(got - @as(i32, rgb[i])) < most);
                }
                try testing.expectEqual(@as(u32, 0xFF), pen >> 24);
            }
        }
    }
}

test "a matrix, a range, a depth or a layout it does not know is refused" {
    try testing.expect(colorsFor(rtg.RTGYUV_BT2020 + 1, rtg.RTGYUV_LIMITED, 8, null) == null);
    try testing.expect(colorsFor(rtg.RTGYUV_BT709, 2, 8, null) == null);
    try testing.expect(colorsFor(rtg.RTGYUV_BT709, rtg.RTGYUV_LIMITED, 12, null) == null);
    const luma align(2) = [_]u8{0} ** 8;
    var picture = rtg.RtgYuv{ .y = &luma, .cb = &luma, .y_pitch = 2, .c_pitch = 2 };
    try testing.expect(Planes.of(&picture, null) != null);
    picture.layout = rtg.RTGYUV_I420;
    try testing.expect(Planes.of(&picture, null) == null);
    picture.cr = &luma;
    try testing.expect(Planes.of(&picture, null) != null);
    picture.layout = 2;
    try testing.expect(Planes.of(&picture, null) == null);

    // Ten bits: the samples are words, so a plane or a pitch on an odd
    // address is refused rather than read across a word.
    picture.layout = rtg.RTGYUV_NV12;
    picture.depth = 10;
    try testing.expect(Planes.of(&picture, null) != null);
    picture.y_pitch = 3;
    try testing.expect(Planes.of(&picture, null) == null);
    picture.y_pitch = 2;
    picture.y = luma[1..].ptr;
    try testing.expect(Planes.of(&picture, null) == null);
}

test "a picture of ten bits says what the same picture of eight says" {
    const colours = [_][3]u8{
        .{ 255, 0, 0 },   .{ 0, 255, 0 },     .{ 0, 0, 255 },    .{ 255, 255, 0 },
        .{ 0, 255, 255 }, .{ 255, 0, 255 },   .{ 200, 100, 50 }, .{ 30, 160, 220 },
        .{ 16, 16, 16 },  .{ 235, 235, 235 },
    };
    for ([_]u8{ rtg.RTGYUV_BT601, rtg.RTGYUV_BT709, rtg.RTGYUV_BT2020 }) |matrix| {
        const kr: f64 = switch (matrix) {
            rtg.RTGYUV_BT601 => 0.299,
            rtg.RTGYUV_BT709 => 0.2126,
            else => 0.2627,
        };
        const kb: f64 = switch (matrix) {
            rtg.RTGYUV_BT601 => 0.114,
            rtg.RTGYUV_BT709 => 0.0722,
            else => 0.0593,
        };
        for ([_]bool{ false, true }) |full| {
            const range: u8 = if (full) rtg.RTGYUV_FULL else rtg.RTGYUV_LIMITED;
            const narrow = colorsFor(matrix, range, 8, null).?;
            const wide = colorsFor(matrix, range, 10, null).?;
            for (colours) |rgb| {
                const r: f64 = @floatFromInt(rgb[0]);
                const g: f64 = @floatFromInt(rgb[1]);
                const b: f64 = @floatFromInt(rgb[2]);
                const eight = encodeAt(kr, kb, full, 8, r, g, b);
                const ten = encodeAt(kr, kb, full, 10, r, g, b);
                const a = penFor(narrow, eight[0], eight[1], eight[2]);
                const c = penFor(wide, ten[0], ten[1], ten[2]);
                for (0..3) |i| {
                    const one: i32 = @intCast(a >> @intCast(16 - i * 8) & 0xFF);
                    const two: i32 = @intCast(c >> @intCast(16 - i * 8) & 0xFF);
                    try testing.expect(@abs(one - two) <= 1);
                }
            }
        }
    }
}

/// PQ's code value for a light given in the screen's whites, the long
/// way in floating point: the curve read backwards.
fn pqCodeOfLight(light: f64) f64 {
    const m1 = 0.1593017578125;
    const m2 = 78.84375;
    const c1 = 0.8359375;
    const c2 = 18.8515625;
    const c3 = 18.6875;
    const y = std.math.pow(f64, @max(light, 0) * display_white / 10000.0, m1);
    return std.math.pow(f64, (c1 + c2 * y) / (1.0 + c3 * y), m2);
}

/// What a pixel of high dynamic range should come out as, worked out the
/// long way: BT.2390's EETF on the largest channel, the film's primaries
/// in the screen's, and BT.709's curve back to a number.
fn toneReference(peak_nits: f64, signal: [3]f64, prim: ?[9]f64) [3]u8 {
    var light: [3]f64 = undefined;
    for (&light, signal) |*one, s| one.* = pqNits(@min(@max(s, 0.0), 1.0)) / display_white;
    // (the tables step a quarter of a byte, so a signal between two steps
    //  lands on one of them - the test allows a step or two for it)
    const high = @max(signal[0], @max(signal[1], signal[2]));
    const came = pqNits(@min(@max(high, 0.0), 1.0)) / display_white;
    if (came > 0) {
        const e_white = pqCodeOfLight(1.0);
        const e_peak = pqCodeOfLight(peak_nits / display_white);
        const max_lum = e_white / e_peak;
        const ks = @max(1.5 * max_lum - 0.5, 0.0);
        const e1 = @min(pqCodeOfLight(came) / e_peak, 1.0);
        var e2 = e1;
        if (e1 > ks) {
            const x = (e1 - ks) / (1.0 - ks);
            const x2 = x * x;
            const x3 = x2 * x;
            e2 = (2 * x3 - 3 * x2 + 1) * ks + (x3 - 2 * x2 + x) * (1.0 - ks) + (3 * x2 - 2 * x3) * max_lum;
        }
        const gone = pqNits(@min(e2 * e_peak, 1.0)) / display_white;
        const gain = gone / came;
        for (&light) |*one| one.* *= gain;
    }
    if (prim) |m| {
        const r = m[0] * light[0] + m[1] * light[1] + m[2] * light[2];
        const g = m[3] * light[0] + m[4] * light[1] + m[5] * light[2];
        const b = m[6] * light[0] + m[7] * light[1] + m[8] * light[2];
        light = .{ r, g, b };
    }
    var out: [3]u8 = undefined;
    for (&out, light) |*one, l| {
        const v = @min(@max(l, 0.0), 1.0);
        const code = if (v < 0.018) 4.5 * v else 1.099 * std.math.pow(f64, v, 0.45) - 0.099;
        one.* = @intFromFloat(@round(@min(@max(code, 0.0), 1.0) * 255.0));
    }
    return out;
}

test "a film of high dynamic range is mapped into the screen's range, within a step or two of the standard" {
    if (!tone_able) return error.SkipZigTest;
    const colours = [_][3]f64{
        .{ 0.0, 0.0, 0.0 }, .{ 0.5081, 0.5081, 0.5081 }, // black, and 100 candelas of grey
        .{ 0.5807, 0.5807, 0.5807 }, // the reference white, 203 candelas
        .{ 0.7518, 0.7518, 0.7518 }, // 1000 candelas: a highlight
        .{ 0.65, 0.20, 0.10 },
        .{ 0.10, 0.62, 0.33 },
        .{ 0.22, 0.30, 0.71 },
        .{ 0.90, 0.80, 0.40 },
    };
    const kr = 0.2627;
    const kb = 0.0593;
    const prim = [9]f64{
        1.660491,  -0.587641, -0.072850,
        -0.124550, 1.132900,  -0.008350,
        -0.018151, -0.100579, 1.118730,
    };
    const luma = [_]u8{0} ** 8;
    for ([_]u16{ 1000, 4000 }) |peak| {
        for ([_]bool{ false, true }) |wide_gamut| {
            var picture = rtg.RtgYuv{
                .y = &luma,
                .cb = &luma,
                .y_pitch = 2,
                .c_pitch = 2,
                .matrix = rtg.RTGYUV_BT2020,
                .transfer = rtg.RTGYUV_PQ,
                .primaries = if (wide_gamut) rtg.RTGYUV_BT2020 else rtg.RTGYUV_BT709,
                .range = rtg.RTGYUV_LIMITED,
                .depth = 10,
                .peak = peak,
            };
            var store: Tone = undefined;
            const tone = toneFor(&picture, &store).?;
            const c = colorsFor(picture.matrix, picture.range, picture.depth, tone).?;
            for (colours) |rgb| {
                const ycc = encodeAt(kr, kb, false, 10, rgb[0] * 255, rgb[1] * 255, rgb[2] * 255);
                const pen = penFor(c, ycc[0], ycc[1], ycc[2]);
                const want = toneReference(@floatFromInt(peak), rgb, if (wide_gamut) prim else null);
                for (0..3) |i| {
                    const got: i32 = @intCast(pen >> @intCast(16 - i * 8) & 0xFF);
                    try testing.expect(@abs(got - @as(i32, want[i])) <= 2);
                }
                try testing.expectEqual(@as(u32, 0xFF), pen >> 24);
            }
        }
    }
}

test "high dynamic range: black stays black, the film's peak reaches the screen's white" {
    if (!tone_able) return error.SkipZigTest;
    const luma = [_]u8{0} ** 8;
    var picture = rtg.RtgYuv{
        .y = &luma,
        .cb = &luma,
        .y_pitch = 2,
        .c_pitch = 2,
        .matrix = rtg.RTGYUV_BT2020,
        .transfer = rtg.RTGYUV_PQ,
        .primaries = rtg.RTGYUV_BT2020,
        .range = rtg.RTGYUV_LIMITED,
        .depth = 10,
        .peak = 1000,
    };
    var store: Tone = undefined;
    const tone = toneFor(&picture, &store).?;
    const c = colorsFor(picture.matrix, picture.range, picture.depth, tone).?;
    try testing.expectEqual(graphics.penRGB(0, 0, 0), penFor(c, 64, 512, 512));
    // 1000 candelas - the peak it says it was mastered for - is the
    // screen's white, and nothing above it goes past white.
    const peak_code: u16 = 64 + @as(u16, @intFromFloat(@round(0.7518 * 876)));
    try testing.expectEqual(graphics.penRGB(255, 255, 255), penFor(c, peak_code, 512, 512));
    try testing.expectEqual(graphics.penRGB(255, 255, 255), penFor(c, 940, 512, 512));
    // The reference white, 203 candelas, lands below the screen's white
    // but well up it - a face is not grey.
    const white_code: u16 = 64 + @as(u16, @intFromFloat(@round(0.5807 * 876)));
    const white = penFor(c, white_code, 512, 512) >> 16 & 0xFF;
    try testing.expect(white > 215 and white < 245);
    // A film whose peak is below the screen's white is not touched at
    // all: every gain is one.
    picture.peak = 100;
    const soft = toneFor(&picture, &store).?;
    for (soft.gain) |one| try testing.expectEqual(@as(u32, 65536), one);
}

test "an ordinary film takes no tables at all" {
    const luma = [_]u8{0} ** 8;
    var picture = rtg.RtgYuv{ .y = &luma, .cb = &luma, .y_pitch = 2, .c_pitch = 2 };
    var store: Tone = undefined;
    try testing.expect(toneFor(&picture, &store) == null);
    picture.transfer = rtg.RTGYUV_PQ;
    try testing.expectEqual(tone_able, toneFor(&picture, &store) != null);
}

test "a walk lands where each division would" {
    for ([_][3]i64{ .{ 0, 3, 7 }, .{ 5 * 7, 7, 3 }, .{ 11, 1920, 1280 }, .{ 2, 5, 5 } }) |w| {
        var walk = Walk.init(w[0], w[1], w[2]);
        for (0..50) |k| {
            try testing.expectEqual(@divFloor(w[0] + @as(i64, @intCast(k)) * w[1], w[2]), walk.at);
            walk.next();
        }
    }
}

test "a walk of stretches gives what spanOf gives each pixel" {
    for ([_][2]i32{ .{ 1920, 1280 }, .{ 1280, 1920 }, .{ 7, 3 }, .{ 3, 7 }, .{ 5, 5 }, .{ 720, 541 } }) |sizes| {
        for ([_]i32{ 0, 3 }) |first| {
            var walk = SpanWalk.init(10 + first, 10, sizes[1], 2, sizes[0]);
            for (0..@intCast(@min(sizes[1] - first, 100))) |k| {
                const want = _blit.spanOf(10 + first + @as(i32, @intCast(k)), 10, sizes[1], 2, sizes[0]);
                const got = walk.take();
                try testing.expectEqual(want.from, got.from);
                try testing.expectEqual(want.to, got.to);
            }
        }
    }
}

test "the chroma's stretch is the luma's halved, and a chroma pixel at least" {
    // Two luma pixels, 0 and 1, are chroma pixel 0.
    const two = chromaSpan(.{ .from = -128, .to = 384 });
    try testing.expectEqual(@as(i64, -128), two.from);
    try testing.expectEqual(@as(i64, 128), two.to);
    // One luma pixel is half a chroma pixel: widened round its middle.
    const one = chromaSpan(.{ .from = -128, .to = 128 });
    try testing.expectEqual(@as(i64, 256), one.to - one.from);
    try testing.expectEqual(@as(i64, -64), @divFloor(one.from + one.to, 2));
    try testing.expectEqual(Rect{ .min_x = 0, .min_y = 1, .max_x = 3, .max_y = 3 }, chromaArea(.{ .min_x = 1, .min_y = 2, .max_x = 5, .max_y = 6 }));
}

test "a piece cut into bands is the piece done whole, every way" {
    var luma: [16 * 12]u8 = undefined;
    var pairs: [16 * 6]u8 = undefined;
    for (&luma, 0..) |*b, i| b.* = @truncate(i * 7 + 16);
    for (&pairs, 0..) |*b, i| b.* = @truncate(i * 13 + 40);
    const picture = rtg.RtgYuv{ .y = &luma, .cb = &pairs, .y_pitch = 16, .c_pitch = 16 };
    const planes = Planes.of(&picture, null).?;
    for ([_]Piece.How{ .straight, .nearest, .smooth }) |how| {
        var whole: [11 * 9 * 4]u8 = @splat(0);
        var banded: [11 * 9 * 4]u8 = @splat(0);
        var piece = Piece{
            .planes = &planes,
            .to = &whole,
            .to_pitch = 11 * 4,
            .format = .bgra32,
            .width = 11,
            .height = 9,
            .how = how,
            .from_x = 3,
            .from_y = 1,
            .x = 2,
            .y = 1,
            .src = .{ .min_x = 1, .min_y = 1, .max_x = 16, .max_y = 12 },
            .dest = .{ .min_x = 0, .min_y = 0, .max_x = 13, .max_y = 10 },
        };
        bandOf(&piece, 0, piece.height);
        piece.to = &banded;
        for (1..5) |parts| {
            @memset(&banded, 0);
            for (0..parts) |part| band(&piece, @intCast(part), @intCast(parts));
            try testing.expectEqualSlices(u8, &whole, &banded);
        }
    }
}
