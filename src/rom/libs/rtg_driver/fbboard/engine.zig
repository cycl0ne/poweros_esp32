// SPDX-License-Identifier: MPL-2.0
//! The fb board's engine: the processor's own cores. A display that reads
//! its picture out of RAM has no drawing engine, so every pixel is the
//! CPU's - and the CPU is several cores on a machine that has them. A job
//! over much of a buffer is cut into bands of rows, and exec's workers, a
//! task on each core, draw them at once with the task that asked
//! (ShareWork): it draws a band itself, and its call returns when every
//! band is drawn. Every job is finished when its call returns, so WaitBlit
//! has only other tasks' to wait for.
//!
//! A job too small to be worth handing out (`smallest`) is drawn by its
//! asker alone, since handing it out costs a few signals between the
//! cores; so is one asked for while exec's workers are busy with another.
//!
//! **What it draws** is what graphics.library draws in software, pixel
//! for pixel - the same sums, rounded the same way - so a picture does
//! not depend on which of the two drew it. It takes buffers of 32 bits a
//! pixel (bgra32); anything else is answered RTGERR_NOT_SUPPORTED, and the
//! caller does that one itself.
//!
//! **Bands** are whole rows, and a band starts on a cache line: a board's
//! rows are whole lines (`row_alignment` in fbboard.zig), and a band's
//! height is rounded to as many rows as a line takes otherwise. Two cores
//! then never write one line.
//!
//! **A copy within one buffer** whose two rectangles overlap cannot be cut
//! into bands that run at once: a band would read rows that another is
//! writing. Rows `d` apart, `d` the rows the copy moves by, form chains,
//! each row read before the row `d` further on is written; the chains do
//! not meet, so each part takes whole chains and walks them away from
//! where the rows are going. A copy along its own rows (`d` 0) is a move
//! within each row, and its rows are bands again.
//!
//! **The caches** are left to the refresh every draw ends with, which
//! writes the rows back for the display with CacheClearE - which exec
//! shares between the cores as well.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const err = rtg.errors;
const ExecBase = sdk.interface.exec.ExecBase;

/// The fewest pixels a job has before it is shared: about 64 KiB of a
/// buffer.
const smallest = 16384;
/// The most parts a job is asked to be cut into: exec cuts it into no
/// more than it has cores for.
const most_parts = 16;
/// The cache line, which a band starts on.
const line_bytes = 64;

/// The engine, in the board's instance.
pub const Engine = struct {
    sys: ?*ExecBase = null,
    /// Held shared by each job while it is drawn, so WaitBlit can wait
    /// for every one under way.
    drawing: exec.SignalSemaphore = .{},
};

pub fn setUp(engine: *Engine, sys: *ExecBase) void {
    engine.* = .{ .sys = sys };
    sys.InitSemaphore(&engine.drawing);
}

/// Until the jobs under way, other tasks', are done.
pub fn waitIdle(engine: *Engine) void {
    const sys = engine.sys orelse return;
    sys.ObtainSemaphore(&engine.drawing);
    sys.ReleaseSemaphore(&engine.drawing);
}

/// `job` done in as many as `wanted` parts, by the asker and exec's
/// workers.
fn share(engine: *Engine, job: Job, wanted: u32) void {
    const sys = engine.sys orelse return job.run(0, 1);
    sys.ObtainSemaphoreShared(&engine.drawing);
    defer sys.ReleaseSemaphore(&engine.drawing);
    var shared = job;
    _ = sys.ShareWork(&runPart, &shared, wanted);
}

/// A part of a job, on whichever core exec gave it to.
fn runPart(data: ?*anyopaque, part: u32, parts: u32) callconv(.c) void {
    const job: *const Job = @ptrCast(@alignCast(data.?));
    job.run(part, parts);
}

/// How many parts a job of `pixels` is worth.
fn partsFor(pixels: u64) u32 {
    return @intCast(@min(pixels / smallest, most_parts));
}

// --- the jobs ----------------------------------------------------------------

/// The rows a job writes, from `first` up to `end`, and how many rows a
/// band is a multiple of so that it starts on a cache line.
const Rows = struct {
    first: u32,
    end: u32,
    step: u32,

    fn of(first: u32, end: u32, pitch: u32) Rows {
        return .{ .first = first, .end = end, .step = line_bytes / std.math.gcd(pitch, line_bytes) };
    }

    /// Part `part` of `parts`: rows `lo` up to `hi`.
    fn band(rows: Rows, part: u32, parts: u32) struct { lo: u32, hi: u32 } {
        const count: u64 = rows.end - rows.first;
        return .{ .lo = rows.at(count * part / parts), .hi = if (part + 1 == parts) rows.end else rows.at(count * (part + 1) / parts) };
    }

    fn at(rows: Rows, offset: u64) u32 {
        return rows.first + @as(u32, @intCast(offset)) / rows.step * rows.step;
    }
};

const Job = union(enum) {
    fill: Fill,
    blend: Blend,
    copy: Copy,
    scale: Scale,
    pattern: Pattern,
    template: Template,
    lay: Lay,

    /// Part `part` of `parts`.
    fn run(job: *const Job, part: u32, parts: u32) void {
        switch (job.*) {
            .copy => |*moving| moving.part(part, parts),
            inline else => |*one| {
                const band = one.rows.band(part, parts);
                if (band.lo < band.hi) one.band(band.lo, band.hi);
            },
        }
    }
};

/// What every job that writes a rectangle of a buffer has: the buffer's
/// first pixel and pitch, and the rectangle's columns.
const Target = struct {
    pixels: [*]u8,
    pitch: u32,
    x: u32,
    width: u32,

    fn row(target: Target, y: u32) [*]u32 {
        return @ptrCast(@alignCast(target.pixels + @as(usize, y) * target.pitch + @as(usize, target.x) * 4));
    }
};

/// Whether the engine draws into `bitmap`: 32 bits a pixel, aligned.
fn drawable(bitmap: *const rtg.RtgBitMap) bool {
    const pixels = bitmap.pixels orelse return false;
    return bitmap.format == .bgra32 and @intFromPtr(pixels) % 4 == 0 and bitmap.pitch % 4 == 0;
}

fn targetOf(bitmap: *const rtg.RtgBitMap, area: *const rtg.RtgRect) Target {
    return .{ .pixels = bitmap.pixels.?, .pitch = bitmap.pitch, .x = @intCast(area.x), .width = @intCast(area.width) };
}

fn rowsOf(bitmap: *const rtg.RtgBitMap, area: *const rtg.RtgRect) Rows {
    return Rows.of(@intCast(area.y), @intCast(area.y + area.height), bitmap.pitch);
}

fn pixelsOf(area: *const rtg.RtgRect) u64 {
    return @as(u64, @intCast(area.width)) * @as(u64, @intCast(area.height));
}

// --- fill --------------------------------------------------------------------

const Fill = struct {
    rows: Rows,
    target: Target,
    color: u32,

    fn band(job: *const Fill, lo: u32, hi: u32) void {
        var y = lo;
        while (y < hi) : (y += 1) fillRun(job.target.row(y), job.target.width, job.color);
    }
};

/// `count` pixels from `to` set to `color`: two at a time, a cache line
/// at a time where it can.
fn fillRun(to: [*]u32, count: u32, color: u32) void {
    var at = to;
    var left = count;
    if (left != 0 and @intFromPtr(at) % 8 != 0) {
        at[0] = color;
        at += 1;
        left -= 1;
    }
    const two = @as(u64, color) << 32 | color;
    var pairs: [*]u64 = @ptrCast(@alignCast(at));
    var n = left / 2;
    while (n >= 8) : (n -= 8) {
        inline for (0..8) |i| pairs[i] = two;
        pairs += 8;
    }
    while (n != 0) : (n -= 1) {
        pairs[0] = two;
        pairs += 1;
    }
    if (left % 2 != 0) @as([*]u32, @ptrCast(pairs))[0] = color;
}

/// FillRect: the rectangle has been clipped to the buffer.
pub fn fill(engine: *Engine, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) i32 {
    if (!drawable(bitmap)) return err.RTGERR_NOT_SUPPORTED;
    share(engine, .{ .fill = .{ .rows = rowsOf(bitmap, area), .target = targetOf(bitmap, area), .color = color } }, partsFor(pixelsOf(area)));
    return err.RTGERR_OK;
}

// --- a colour laid over ------------------------------------------------------

/// x / 255 rounded down, for x up to 255 * 255 + 255.
inline fn div255(x: u32) u32 {
    return (x + 1 + (x >> 8)) >> 8;
}

/// The same for two values a half-word each, as red and blue lie in a
/// pixel.
inline fn div255Pair(x: u32) u32 {
    return (x + 0x0001_0001 + (x >> 8 & 0x00FF_00FF)) >> 8 & 0x00FF_00FF;
}

/// A colour of coverage `alpha` (1 to 254) laid over `under`, as
/// graphics.library's `over` lays it: each channel rounded, the result
/// opaque. `rb` and `g` are the colour's red and blue and its green, each
/// times the alpha and 127 more.
inline fn mix(under: u32, rb: u32, g: u32, inverse: u32) u32 {
    const under_rb = (under & 0x00FF_00FF) * inverse + rb;
    const under_g = (under >> 8 & 0xFF) * inverse + g;
    return 0xFF00_0000 | div255Pair(under_rb) | div255(under_g) << 8;
}

const Blend = struct {
    rows: Rows,
    target: Target,
    rb: u32,
    g: u32,
    inverse: u32,

    fn band(job: *const Blend, lo: u32, hi: u32) void {
        var y = lo;
        while (y < hi) : (y += 1) {
            const row = job.target.row(y);
            for (row[0..job.target.width]) |*pixel| pixel.* = mix(pixel.*, job.rb, job.g, job.inverse);
        }
    }
};

/// The parts of a colour `mix` takes.
fn mixOf(color: u32, alpha: u32) struct { rb: u32, g: u32 } {
    return .{
        .rb = ((color >> 16 & 0xFF) * alpha + 127) << 16 | ((color & 0xFF) * alpha + 127),
        .g = (color >> 8 & 0xFF) * alpha + 127,
    };
}

/// BlendRect: the rectangle has been clipped to the buffer. A colour of no
/// coverage changes nothing, and one of full coverage is a fill.
pub fn blendRect(engine: *Engine, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) i32 {
    if (!drawable(bitmap)) return err.RTGERR_NOT_SUPPORTED;
    const alpha = color >> 24;
    if (alpha == 0) return err.RTGERR_OK;
    if (alpha == 0xFF) return fill(engine, bitmap, area, color);
    const parts = mixOf(color, alpha);
    share(engine, .{ .blend = .{
        .rows = rowsOf(bitmap, area),
        .target = targetOf(bitmap, area),
        .rb = parts.rb,
        .g = parts.g,
        .inverse = 255 - alpha,
    } }, partsFor(pixelsOf(area)));
    return err.RTGERR_OK;
}

// --- a picture laid over -----------------------------------------------------

const Lay = struct {
    rows: Rows,
    target: Target,
    /// The picture's pixel that lands on the rectangle's top left, and
    /// the bytes from one of its rows to the next.
    picture: [*]const u8,
    picture_pitch: u32,
    /// Red and blue the other way round: a picture in rgba32.
    swap: bool,
    /// The strength it is laid at, 1 to 255.
    alpha: u32,
    /// Every pixel covers fully, whatever its top byte says
    /// (`RTGPIXF_OPAQUE`): laid at `alpha` alone.
    whole: bool,

    fn band(job: *const Lay, lo: u32, hi: u32) void {
        var y = lo;
        while (y < hi) : (y += 1) {
            const in: [*]const u32 = @ptrCast(@alignCast(job.picture + @as(usize, y - job.rows.first) * job.picture_pitch));
            const out = job.target.row(y);
            const count = job.target.width;
            const full = job.alpha == 255;
            if (job.whole) {
                if (job.swap) wholeRow(out, in, count, job.alpha, true) else wholeRow(out, in, count, job.alpha, false);
            } else if (job.swap) {
                if (full) layRow(out, in, count, 255, true, true) else layRow(out, in, count, job.alpha, true, false);
            } else {
                if (full) layRow(out, in, count, 255, false, true) else layRow(out, in, count, job.alpha, false, false);
            }
        }
    }
};

/// A row of a picture laid over a row of the buffer as graphics.library's
/// `blendPixel` lays each pixel: by its coverage - times `alpha` / 256 for
/// a picture laid at less than full strength, as the S3's engine does it -
/// a pixel fully covered stored as it is, one not covered left alone.
fn layRow(out: [*]u32, in: [*]const u32, count: u32, alpha: u32, comptime swap: bool, comptime full: bool) void {
    for (out[0..count], in[0..count]) |*pixel, source| {
        const pen = if (swap) (source & 0xFF00_FF00) | (source >> 16 & 0xFF) | (source & 0xFF) << 16 else source;
        const coverage = if (full) pen >> 24 else (pen >> 24) * alpha >> 8;
        if (coverage == 0xFF) {
            pixel.* = pen;
        } else if (coverage != 0) {
            const parts = mixOf(pen, coverage);
            pixel.* = mix(pixel.*, parts.rb, parts.g, 255 - coverage);
        }
    }
}

/// A row of a picture that covers fully laid over a row of the buffer at
/// `alpha`, the same for every pixel.
fn wholeRow(out: [*]u32, in: [*]const u32, count: u32, alpha: u32, comptime swap: bool) void {
    if (alpha == 255) {
        for (out[0..count], in[0..count]) |*pixel, source| {
            pixel.* = if (swap) (source & 0xFF00_FF00) | (source >> 16 & 0xFF) | (source & 0xFF) << 16 else source;
        }
        return;
    }
    for (out[0..count], in[0..count]) |*pixel, source| {
        const pen = if (swap) (source & 0xFF00_FF00) | (source >> 16 & 0xFF) | (source & 0xFF) << 16 else source;
        const parts = mixOf(pen, alpha);
        pixel.* = mix(pixel.*, parts.rb, parts.g, 255 - alpha);
    }
}

/// BlendPixels: the rectangle has been clipped to the buffer, and the
/// picture's corner moved with it. A picture of 32 bits a pixel with its
/// coverage in the top byte, red and blue either way round (bgra32,
/// rgba32), and not in the rows it is laid over: bands that run at once
/// would read what another has written.
pub fn blendPixels(engine: *Engine, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, alpha: u32) i32 {
    if (!drawable(bitmap)) return err.RTGERR_NOT_SUPPORTED;
    const picture = pixels.pixels orelse return err.RTGERR_NOT_SUPPORTED;
    if (pixels.format != .bgra32 and pixels.format != .rgba32) return err.RTGERR_NOT_SUPPORTED;
    if (@intFromPtr(picture) % 4 != 0 or pixels.pitch % 4 != 0) return err.RTGERR_NOT_SUPPORTED;
    if (pixels.x < 0 or pixels.y < 0) return err.RTGERR_NOT_SUPPORTED;
    if (alpha == 0) return err.RTGERR_OK;
    const width: u32 = @intCast(area.width);
    const height: u32 = @intCast(area.height);
    const first = picture + @as(usize, @intCast(pixels.y)) * pixels.pitch + @as(usize, @intCast(pixels.x)) * 4;
    const picture_start = @intFromPtr(first);
    const picture_end = picture_start + @as(usize, height - 1) * pixels.pitch + @as(usize, width) * 4;
    const dest_start = rowAddress(bitmap, @intCast(area.x), @intCast(area.y));
    const dest_end = rowAddress(bitmap, @intCast(area.x + area.width), @intCast(area.y + area.height - 1));
    if (picture_start < dest_end and dest_start < picture_end) return err.RTGERR_NOT_SUPPORTED;
    share(engine, .{ .lay = .{
        .rows = rowsOf(bitmap, area),
        .target = targetOf(bitmap, area),
        .picture = first,
        .picture_pitch = pixels.pitch,
        .swap = pixels.format == .rgba32,
        .alpha = @min(alpha, 255),
        .whole = pixels.flags & rtg.RTGPIXF_OPAQUE != 0,
    } }, partsFor(pixelsOf(area)));
    return err.RTGERR_OK;
}

// --- copy --------------------------------------------------------------------

const Copy = struct {
    /// The destination's rows, and its row `rows.first` is the source's
    /// row `src_first`.
    rows: Rows,
    dest: [*]u8,
    dest_pitch: u32,
    dest_x: u32,
    src: [*]const u8,
    src_pitch: u32,
    src_x: u32,
    src_first: u32,
    bytes: u32,
    /// 0: the rows are bands. Else the rows the copy moves by, and whether
    /// it moves them down, so that a chain is walked from its bottom.
    chain: u32,
    down: bool,
    /// Whether the source and the destination of a row may overlap.
    within_rows: bool,

    fn row(job: *const Copy, y: u32) void {
        const to = job.dest + @as(usize, y) * job.dest_pitch + @as(usize, job.dest_x) * 4;
        const from = job.src + @as(usize, job.src_first + (y - job.rows.first)) * job.src_pitch + @as(usize, job.src_x) * 4;
        if (job.within_rows) {
            @memmove(to[0..job.bytes], from[0..job.bytes]);
        } else {
            @memcpy(to[0..job.bytes], from[0..job.bytes]);
        }
    }

    fn part(job: *const Copy, which: u32, parts: u32) void {
        if (job.chain == 0) {
            const band = job.rows.band(which, parts);
            var y = band.lo;
            while (y < band.hi) : (y += 1) job.row(y);
            return;
        }
        // The chains starting at the rows of this part of the first run
        // of `chain` rows, each walked whole.
        const lo = job.rows.first + job.chain * which / parts;
        const hi = job.rows.first + job.chain * (which + 1) / parts;
        var start = lo;
        while (start < hi and start < job.rows.end) : (start += 1) {
            const links = (job.rows.end - 1 - start) / job.chain;
            var k: u32 = 0;
            while (k <= links) : (k += 1) {
                const step = if (job.down) links - k else k;
                job.row(start + step * job.chain);
            }
        }
    }
};

fn rowAddress(bitmap: *const rtg.RtgBitMap, x: u32, y: u32) usize {
    return @intFromPtr(bitmap.pixels.?) + @as(usize, y) * bitmap.pitch + @as(usize, x) * 4;
}

/// CopyRect: both rectangles have been clipped to their buffers. The
/// source may be any memory of the same format; one that overlaps the
/// destination other than as the same buffer is refused.
pub fn copy(engine: *Engine, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, what: *const rtg.RtgCopy) i32 {
    if (!drawable(dest) or !drawable(src)) return err.RTGERR_NOT_SUPPORTED;
    const sx: u32 = @intCast(what.src_x);
    const sy: u32 = @intCast(what.src_y);
    const dx: u32 = @intCast(what.dest_x);
    const dy: u32 = @intCast(what.dest_y);
    const width: u32 = @intCast(what.width);
    const height: u32 = @intCast(what.height);
    var job = Copy{
        .rows = Rows.of(dy, dy + height, dest.pitch),
        .dest = dest.pixels.?,
        .dest_pitch = dest.pitch,
        .dest_x = dx,
        .src = src.pixels.?,
        .src_pitch = src.pitch,
        .src_x = sx,
        .src_first = sy,
        .bytes = width * 4,
        .chain = 0,
        .down = false,
        .within_rows = false,
    };
    const src_first = rowAddress(src, sx, sy);
    const src_end = rowAddress(src, sx + width, sy + height - 1);
    const dest_first = rowAddress(dest, dx, dy);
    const dest_end = rowAddress(dest, dx + width, dy + height - 1);
    var parts = partsFor(@as(u64, width) * height);
    if (src_first < dest_end and dest_first < src_end) {
        // The two meet: only as one buffer, with one pitch.
        if (src.pixels != dest.pixels or src.pitch != dest.pitch) return err.RTGERR_NOT_SUPPORTED;
        const rects_meet = sx < dx + width and dx < sx + width and sy < dy + height and dy < sy + height;
        if (rects_meet) {
            if (sy == dy) {
                job.within_rows = true;
            } else {
                job.chain = if (dy > sy) dy - sy else sy - dy;
                job.down = dy > sy;
                parts = @min(parts, job.chain);
            }
        }
    }
    share(engine, .{ .copy = job }, parts);
    return err.RTGERR_OK;
}

// --- a picture scaled --------------------------------------------------------

/// Where a destination column takes its pixels from: the two source
/// columns either side, and how far between them, in 256ths.
const Column = struct { x0: u32, x1: u32, w: u32 };

/// graphics.library's `sourceOf`: where the middle of a destination pixel
/// falls in the source, in 256ths of a source pixel.
fn sourceOf(dest: i64, dest_start: i64, dest_size: i64, src_start: i64, src_size: i64) i64 {
    const offset = (dest - dest_start) * 2 + 1;
    return src_start * 256 + @divFloor(offset * src_size * 256, 2 * dest_size) - 128;
}

/// The two source pixels either side of `f` (in 256ths), kept inside
/// `min` to `max`, and the weight of the second: as sampleBetween takes
/// them.
fn between(f: i64, min: i64, max: i64) Column {
    const first = @max(@min(@divFloor(f, 256), max - 1), min);
    const second = @min(first + 1, max - 1);
    const w = @max(@min(f - first * 256, 255), 0);
    return .{ .x0 = @intCast(first), .x1 = @intCast(second), .w = @intCast(w) };
}

const Scale = struct {
    rows: Rows,
    target: Target,
    picture: [*]const u8,
    picture_pitch: u32,
    /// The part of the picture taken, and where the destination's rows
    /// start and how many there are.
    src_top: i32,
    src_bottom: i32,
    dest_top: i32,
    dest_height: i32,
    columns: [*]const Column,

    fn band(job: *const Scale, lo: u32, hi: u32) void {
        const src_height: i64 = job.src_bottom - job.src_top;
        var y = lo;
        while (y < hi) : (y += 1) {
            const fy = sourceOf(y, job.dest_top, job.dest_height, job.src_top, src_height);
            const rows = between(fy, job.src_top, job.src_bottom);
            const top: [*]const u32 = @ptrCast(@alignCast(job.picture + @as(usize, rows.x0) * job.picture_pitch));
            const bottom: [*]const u32 = @ptrCast(@alignCast(job.picture + @as(usize, rows.x1) * job.picture_pitch));
            const wy = rows.w;
            const out = job.target.row(y);
            for (out[0..job.target.width], job.columns[0..job.target.width]) |*pixel, column| {
                const wx = column.w;
                const pen = sample(
                    .{ top[column.x0], top[column.x1], bottom[column.x0], bottom[column.x1] },
                    .{ (256 - wx) * (256 - wy), wx * (256 - wy), (256 - wx) * wy, wx * wy },
                );
                const alpha = pen >> 24;
                if (alpha == 0xFF) {
                    pixel.* = pen;
                } else if (alpha != 0) {
                    const parts = mixOf(pen, alpha);
                    pixel.* = mix(pixel.*, parts.rb, parts.g, 255 - alpha);
                }
            }
        }
    }
};

/// Four pixels mixed by their weights, which make 65536: each channel the
/// weighted sum, rounded - two channels at a time, a word each.
inline fn sample(corners: [4]u32, weights: [4]u32) u32 {
    var blue_red: u64 = 0;
    var green_alpha: u64 = 0;
    inline for (corners, weights) |c, w| {
        blue_red += ((c & 0xFF) | @as(u64, c >> 16 & 0xFF) << 32) * w;
        green_alpha += ((c >> 8 & 0xFF) | @as(u64, c >> 24) << 32) * w;
    }
    const half = 32768;
    const blue: u32 = @intCast(((blue_red & 0xFFFF_FFFF) + half) >> 16);
    const red: u32 = @intCast(((blue_red >> 32) + half) >> 16);
    const green: u32 = @intCast(((green_alpha & 0xFFFF_FFFF) + half) >> 16);
    const alpha: u32 = @intCast(((green_alpha >> 32) + half) >> 16);
    return alpha << 24 | red << 16 | green << 8 | blue;
}

/// ScalePixels: the rectangle lies inside the buffer; the picture's part
/// is `width` by `height` from its corner. A picture of 32 bits a pixel
/// with its coverage in the top byte (bgra32) only.
pub fn scale(engine: *Engine, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, width: u32, height: u32) i32 {
    if (!drawable(bitmap)) return err.RTGERR_NOT_SUPPORTED;
    const picture = pixels.pixels orelse return err.RTGERR_NOT_SUPPORTED;
    if (pixels.format != .bgra32 or @intFromPtr(picture) % 4 != 0 or pixels.pitch % 4 != 0) return err.RTGERR_NOT_SUPPORTED;
    if (pixels.x < 0 or pixels.y < 0) return err.RTGERR_NOT_SUPPORTED;
    const sys = engine.sys orelse return err.RTGERR_NOT_SUPPORTED;
    const dest_width: u32 = @intCast(area.width);
    const table = sys.AllocVec(@as(usize, dest_width) * @sizeOf(Column), exec.MEMF_ANY) orelse return err.RTGERR_NOT_SUPPORTED;
    defer sys.FreeVec(table);
    const columns: [*]Column = @ptrCast(@alignCast(table));
    const left: i64 = pixels.x;
    for (columns[0..dest_width], 0..) |*column, i| {
        const fx = sourceOf(area.x + @as(i64, @intCast(i)), area.x, area.width, left, width);
        column.* = between(fx, left, left + width);
    }
    share(engine, .{ .scale = .{
        .rows = rowsOf(bitmap, area),
        .target = targetOf(bitmap, area),
        .picture = picture,
        .picture_pitch = pixels.pitch,
        .src_top = pixels.y,
        .src_bottom = pixels.y + @as(i32, @intCast(height)),
        .dest_top = area.y,
        .dest_height = area.height,
        .columns = columns,
    } }, partsFor(pixelsOf(area) * 4));
    return err.RTGERR_OK;
}

// --- shapes of one bit a pixel -----------------------------------------------

/// The two colours a shape is painted in, and what its bits mean.
const Pens = struct {
    fg: u32,
    bg: u32,
    /// A clear bit leaves the pixel alone; set and clear are swapped.
    transparent: bool,
    invert: bool,

    fn of(fg: u32, bg: u32, flags: u32) Pens {
        return .{
            .fg = fg,
            .bg = bg,
            .transparent = flags & rtg.bitmaps.RTGTF_TRANSPARENT != 0,
            .invert = flags & rtg.bitmaps.RTGTF_INVERT != 0,
        };
    }

    inline fn put(pens: Pens, pixel: *u32, set: bool) void {
        if (set != pens.invert) {
            pixel.* = pens.fg;
        } else if (!pens.transparent) {
            pixel.* = pens.bg;
        }
    }
};

inline fn bitAt(line: [*]const u8, column: u32) bool {
    return line[column >> 3] >> @intCast(7 - (column & 7)) & 1 != 0;
}

const Pattern = struct {
    rows: Rows,
    target: Target,
    bits: [*]const u8,
    pitch: u32,
    width: u32,
    height: u32,
    origin_x: i32,
    origin_y: i32,
    pens: Pens,

    fn band(job: *const Pattern, lo: u32, hi: u32) void {
        const first_col: u32 = @intCast(@mod(@as(i64, job.target.x) - job.origin_x, job.width));
        var y = lo;
        while (y < hi) : (y += 1) {
            const tile_row: usize = @intCast(@mod(@as(i64, y) - job.origin_y, job.height));
            const line = job.bits + tile_row * job.pitch;
            var col = first_col;
            for (job.target.row(y)[0..job.target.width]) |*pixel| {
                job.pens.put(pixel, bitAt(line, col));
                col += 1;
                if (col == job.width) col = 0;
            }
        }
    }
};

/// BlitPattern: the rectangle has been clipped to the buffer.
pub fn pattern(engine: *Engine, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, tile: *const rtg.bitmaps.RtgPattern) i32 {
    if (!drawable(bitmap)) return err.RTGERR_NOT_SUPPORTED;
    const bits = tile.bits orelse return err.RTGERR_NOT_SUPPORTED;
    if (tile.width == 0 or tile.height == 0) return err.RTGERR_NOT_SUPPORTED;
    share(engine, .{ .pattern = .{
        .rows = rowsOf(bitmap, area),
        .target = targetOf(bitmap, area),
        .bits = bits,
        .pitch = tile.pitch,
        .width = tile.width,
        .height = tile.height,
        .origin_x = tile.origin_x,
        .origin_y = tile.origin_y,
        .pens = Pens.of(tile.fg, tile.bg, tile.flags),
    } }, partsFor(pixelsOf(area)));
    return err.RTGERR_OK;
}

const Template = struct {
    rows: Rows,
    target: Target,
    bits: [*]const u8,
    pitch: u32,
    /// The bit for the rectangle's top left.
    src_x: u32,
    src_y: u32,
    pens: Pens,

    fn band(job: *const Template, lo: u32, hi: u32) void {
        var y = lo;
        while (y < hi) : (y += 1) {
            const line = job.bits + @as(usize, job.src_y + (y - job.rows.first)) * job.pitch;
            for (job.target.row(y)[0..job.target.width], 0..) |*pixel, i| {
                job.pens.put(pixel, bitAt(line, job.src_x + @as(u32, @intCast(i))));
            }
        }
    }
};

/// BlitTemplate: the rectangle has been clipped to the buffer.
pub fn template(engine: *Engine, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, shape: *const rtg.bitmaps.RtgTemplate) i32 {
    if (!drawable(bitmap)) return err.RTGERR_NOT_SUPPORTED;
    const bits = shape.bits orelse return err.RTGERR_NOT_SUPPORTED;
    share(engine, .{ .template = .{
        .rows = rowsOf(bitmap, area),
        .target = targetOf(bitmap, area),
        .bits = bits,
        .pitch = shape.pitch,
        .src_x = shape.src_x,
        .src_y = shape.src_y,
        .pens = Pens.of(shape.fg, shape.bg, shape.flags),
    } }, partsFor(pixelsOf(area)));
    return err.RTGERR_OK;
}
