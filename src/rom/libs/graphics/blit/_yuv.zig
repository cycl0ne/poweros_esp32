// SPDX-License-Identifier: MPL-2.0
//! YUV pictures turned into colours: what WriteYUVPixelArray and
//! ScaleYUVPixelArray share.
//!
//! A video frame is a plane of brightness (Y) and the colour (Cb, Cr) at
//! half the size each way, 4:2:0. Each pixel's colour comes from its Y
//! and the Cb and Cr of the two by two it is in, through the picture's
//! matrix - BT.601's or BT.709's - and range, in 16-bit fixed point: a
//! multiply for the luma and four for the chroma, whose terms the two
//! pixels of a pair share. The chroma is taken to sit in the middle of
//! its four pixels, where JPEG and MPEG-1 put it; MPEG-2 and H.264 put it
//! a quarter of a pixel further left, which no one sees.
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
/// Cr each taken from their middle, 128 - times its factor for each.
pub const Colors = struct {
    luma: i32,
    /// The Y that is black: 16 in video's range, 0 in the whole byte.
    black: i32,
    cr_red: i32,
    cb_green: i32,
    cr_green: i32,
    cb_blue: i32,
};

/// A matrix's factors, from its weights for red (`kr`) and blue (`kb`):
/// R = Y + 2(1 - kr) Cr, B = Y + 2(1 - kb) Cb, and G what is left of Y
/// once those are taken out. Video's range stretches Y's 219 steps and
/// the chroma's 224 to the whole byte.
fn colorsOf(comptime kr: f64, comptime kb: f64, comptime full: bool) Colors {
    const kg = 1.0 - kr - kb;
    const luma: f64 = if (full) 1.0 else 255.0 / 219.0;
    const chroma: f64 = if (full) 1.0 else 255.0 / 224.0;
    const one = 65536.0;
    return .{
        .luma = @intFromFloat(@round(luma * one)),
        .black = if (full) 0 else 16,
        .cr_red = @intFromFloat(@round(2.0 * (1.0 - kr) * chroma * one)),
        .cb_green = @intFromFloat(@round(2.0 * (1.0 - kb) * kb / kg * chroma * one)),
        .cr_green = @intFromFloat(@round(2.0 * (1.0 - kr) * kr / kg * chroma * one)),
        .cb_blue = @intFromFloat(@round(2.0 * (1.0 - kb) * chroma * one)),
    };
}

/// BT.601 and BT.709, each in video's range and then the whole byte.
const known = [_]Colors{
    colorsOf(0.299, 0.114, false),
    colorsOf(0.299, 0.114, true),
    colorsOf(0.2126, 0.0722, false),
    colorsOf(0.2126, 0.0722, true),
};

/// The factors `RtgYuv.colors` names, or null for a matrix this library
/// does not know or a bit it does not.
pub fn colorsFor(colors: u8) ?Colors {
    if (colors & ~(rtg.RTGYUV_MATRIX | rtg.RTGYUV_FULL) != 0) return null;
    const matrix = colors & rtg.RTGYUV_MATRIX;
    if (matrix > rtg.RTGYUV_BT709) return null;
    return known[@as(usize, matrix) * 2 + @intFromBool(colors & rtg.RTGYUV_FULL != 0)];
}

/// The chroma's share of a pair's colour, the rounding in it: what each
/// of the pair adds its own luma to.
const Chroma = struct {
    red: i32,
    green: i32,
    blue: i32,
};

// The sums of a pixel cannot overflow - a factor is below 2^18 and a
// byte's distance from its middle below 2^8 - so they wrap rather than
// being checked, which keeps a branch a sum out of the loop of every
// pixel.
inline fn chromaOf(c: Colors, cb: u8, cr: u8) Chroma {
    const u = @as(i32, cb) - 128;
    const v = @as(i32, cr) - 128;
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

inline fn penOf(c: Colors, y: u8, chroma: Chroma) Pen {
    const l = c.luma *% (@as(i32, y) - c.black);
    return 0xFF000000 | byte(l +% chroma.red) << 16 | byte(l +% chroma.green) << 8 | byte(l +% chroma.blue);
}

/// The colour of one Y, Cb and Cr.
pub fn penFor(c: Colors, y: u8, cb: u8, cr: u8) Pen {
    return penOf(c, y, chromaOf(c, cb, cr));
}

/// A picture's planes, checked: where its luma and each chroma byte are,
/// and the factors for its colours.
pub const Planes = struct {
    y: [*]const u8,
    cb: [*]const u8,
    cr: [*]const u8,
    y_pitch: usize,
    c_pitch: usize,
    /// Bytes from one Cb (or Cr) to the next across: two in NV12's plane
    /// of pairs, one in I420's planes.
    step: usize,
    colors: Colors,

    /// The planes of `picture`, or null for a layout or colours this
    /// library does not know, or an I420 picture with no Cr plane.
    pub fn of(picture: *const rtg.RtgYuv) ?Planes {
        const colors = colorsFor(picture.colors) orelse return null;
        return switch (picture.layout) {
            rtg.RTGYUV_NV12 => .{
                .y = picture.y,
                .cb = picture.cb,
                .cr = picture.cb + 1,
                .y_pitch = picture.y_pitch,
                .c_pitch = picture.c_pitch,
                .step = 2,
                .colors = colors,
            },
            rtg.RTGYUV_I420 => .{
                .y = picture.y,
                .cb = picture.cb,
                .cr = picture.cr orelse return null,
                .y_pitch = picture.y_pitch,
                .c_pitch = picture.c_pitch,
                .step = 1,
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
        putAs(format, words, to, i, penOf(c, luma[x], chromaOf(c, cb[k], cr[k])));
        x += 1;
        i += 1;
    }
    var k = (x >> 1) * step;
    while (x + 2 <= end) : ({
        x += 2;
        i += 2;
        k += step;
    }) {
        const chroma = chromaOf(c, cb[k], cr[k]);
        putAs(format, words, to, i, penOf(c, luma[x], chroma));
        putAs(format, words, to, i + 1, penOf(c, luma[x + 1], chroma));
    }
    if (x < end) putAs(format, words, to, i, penOf(c, luma[x], chromaOf(c, cb[k], cr[k])));
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
            chroma = chromaOf(c, cb[k], cr[k]);
            last = k;
        }
        putAs(format, words, to, i, penOf(c, luma[sx], chroma));
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
fn meanOver(plane: [*]const u8, pitch: usize, step: usize, area: Rect, across: Span, down: Span) u8 {
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
        var row_total: u64 = 0;
        var x = first_x;
        while (x <= last_x) : (x += 1) {
            const weight_x = across.share(x);
            row += @as(u64, line[@as(usize, @intCast(x)) * step]) * weight_x;
            row_total += weight_x;
        }
        sum += row * weight_y;
        total += row_total * weight_y;
    }
    if (total == 0) {
        const x: usize = @intCast(@min(@max(first_x, area.min_x), area.max_x - 1));
        return plane[@as(usize, @intCast(@min(@max(first_y, area.min_y), area.max_y - 1))) * pitch + x * step];
    }
    return @intCast((sum + total / 2) / total);
}

/// `meanOver` of the Cb and the Cr together: they lie alike, so each
/// share is worked out once for the two.
fn meanOfPair(cb: [*]const u8, cr: [*]const u8, pitch: usize, step: usize, area: Rect, across: Span, down: Span) [2]u8 {
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
            row[0] += @as(u64, cb[at]) * weight_x;
            row[1] += @as(u64, cr[at]) * weight_x;
            row_total += weight_x;
        }
        sums[0] += row[0] * weight_y;
        sums[1] += row[1] * weight_y;
        total += row_total * weight_y;
    }
    if (total == 0) {
        const x: usize = @intCast(@min(@max(first_x, area.min_x), area.max_x - 1));
        const at = @as(usize, @intCast(@min(@max(first_y, area.min_y), area.max_y - 1))) * pitch + x * step;
        return .{ cb[at], cr[at] };
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
            const luma = meanOver(p.y, p.y_pitch, 1, src, across, down);
            const chroma = meanOfPair(p.cb, p.cr, p.c_pitch, p.step, chroma_area, chromaSpan(across), chroma_down);
            const pen = penFor(c, luma, chroma[0], chroma[1]);
            rows.store(to + i * to_bytes, to_bytes, rastport.packPen(piece.format, pen) orelse 0);
        }
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "black, white and grey come out as themselves in every matrix and range" {
    for ([_]u8{ rtg.RTGYUV_BT601, rtg.RTGYUV_BT709 }) |matrix| {
        const video = colorsFor(matrix).?;
        try testing.expectEqual(graphics.penRGB(0, 0, 0), penFor(video, 16, 128, 128));
        try testing.expectEqual(graphics.penRGB(255, 255, 255), penFor(video, 235, 128, 128));
        try testing.expectEqual(graphics.penRGB(128, 128, 128), penFor(video, 126, 128, 128));
        // Below black and above white is held to them.
        try testing.expectEqual(graphics.penRGB(0, 0, 0), penFor(video, 0, 128, 128));
        try testing.expectEqual(graphics.penRGB(255, 255, 255), penFor(video, 255, 128, 128));

        const full = colorsFor(matrix | rtg.RTGYUV_FULL).?;
        try testing.expectEqual(graphics.penRGB(0, 0, 0), penFor(full, 0, 128, 128));
        try testing.expectEqual(graphics.penRGB(255, 255, 255), penFor(full, 255, 128, 128));
        try testing.expectEqual(graphics.penRGB(77, 77, 77), penFor(full, 77, 128, 128));
    }
}

/// The Y, Cb and Cr of a colour, worked out the long way in floating
/// point - what an encoder does.
fn encode(kr: f64, kb: f64, full: bool, r: f64, g: f64, b: f64) [3]u8 {
    const y = kr * r + (1 - kr - kb) * g + kb * b;
    const pb = (b - y) / (2 * (1 - kb));
    const pr = (r - y) / (2 * (1 - kr));
    const scale_y: f64 = if (full) 255 else 219;
    const scale_c: f64 = if (full) 255 else 224;
    const black: f64 = if (full) 0 else 16;
    // The whole byte's chroma reaches half a step past 255 at the edge.
    return .{
        @intFromFloat(@round(black + y * scale_y / 255)),
        @intFromFloat(@min(@round(128 + pb * scale_c / 255), 255)),
        @intFromFloat(@min(@round(128 + pr * scale_c / 255), 255)),
    };
}

test "the primaries and their mixes come back within a step of themselves" {
    const matrices = [_]struct { colors: u8, kr: f64, kb: f64 }{
        .{ .colors = rtg.RTGYUV_BT601, .kr = 0.299, .kb = 0.114 },
        .{ .colors = rtg.RTGYUV_BT709, .kr = 0.2126, .kb = 0.0722 },
    };
    const colours = [_][3]u8{
        .{ 255, 0, 0 },   .{ 0, 255, 0 },   .{ 0, 0, 255 },    .{ 255, 255, 0 },
        .{ 0, 255, 255 }, .{ 255, 0, 255 }, .{ 200, 100, 50 }, .{ 30, 160, 220 },
    };
    for (matrices) |m| {
        for ([_]bool{ false, true }) |full| {
            const c = colorsFor(m.colors | if (full) rtg.RTGYUV_FULL else 0).?;
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

test "a matrix, a range or a layout it does not know is refused" {
    try testing.expect(colorsFor(2) == null);
    try testing.expect(colorsFor(rtg.RTGYUV_BT709 | 0x40) == null);
    const luma = [_]u8{0} ** 4;
    var picture = rtg.RtgYuv{ .y = &luma, .cb = &luma, .y_pitch = 2, .c_pitch = 2 };
    try testing.expect(Planes.of(&picture) != null);
    picture.layout = rtg.RTGYUV_I420;
    try testing.expect(Planes.of(&picture) == null);
    picture.cr = &luma;
    try testing.expect(Planes.of(&picture) != null);
    picture.layout = 2;
    try testing.expect(Planes.of(&picture) == null);
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
    const planes = Planes.of(&picture).?;
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
