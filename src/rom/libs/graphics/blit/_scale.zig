// SPDX-License-Identifier: MPL-2.0
//! A picture scaled smooth between two surfaces of 32 bits a pixel, each
//! `bgra32` or `rgba32`, by every core where there is enough of it
//! (`rows/_bands.zig`).
//!
//! It is what `sampleBetween` and `sampleOver` answer for every pixel -
//! the same sums, rounded the same way - with what a column takes worked
//! out once for the job and not once a pixel: the two source columns
//! either side of it and how far between them, or, where the picture is
//! made smaller either way, the stretch of the source it is the mean of.
//! A whole pixel is one load and one store. Every channel is worked out
//! by itself, so the sums are the same in either order of red and blue:
//! a pixel of the picture's order is put down in the surface's, its red
//! and blue swapped where the two differ.
//!
//! How a pixel lands is the caller's to say, as its own loop has it:
//! stored as it is, or laid over what is there by its coverage.
//!
//! The columns' table is asked of exec for the job; without the memory,
//! or for any other pair of formats, the answer is false and the caller
//! takes its loop of a pixel at a time.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const Rect = graphics.Rect;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const drawing = @import("../draw/_draw.zig");
const bands = @import("../rows/_bands.zig");
const _blit = @import("_blit.zig");

/// Where a destination column takes its pixels from: the two source
/// columns either side, and how far between them, in 256ths.
const Between = struct { first: u32, second: u32, weight: u32 };

/// The two source pixels either side of `place` (in 256ths), kept inside
/// `min` up to `max`, and the weight of the second: as `sampleBetween`
/// takes them.
fn between(place: i64, min: i32, max: i32) Between {
    const first: i32 = @intCast(@max(@min(@divFloor(place, 256), max - 1), min));
    const second = @min(first + 1, max - 1);
    const weight = @max(@min(place - @as(i64, first) * 256, 255), 0);
    return .{ .first = @intCast(first), .second = @intCast(second), .weight = @intCast(weight) };
}

/// The stretch of the source a destination column or row is the mean
/// of, and the first and last pixel of the part taken that some of it
/// covers: as `sampleOver` takes them.
const Over = struct {
    span: _blit.Span,
    first: i32,
    last: i32,

    fn of(span: _blit.Span, min: i32, max: i32) Over {
        return .{ .span = span, .first = @max(span.first(), min), .last = @min(span.last(), max - 1) };
    }
};

/// How a scaled pixel lands.
pub const Land = enum {
    /// Stored as it is.
    store,
    /// Laid over what is there by its coverage.
    lay,
};

const Smooth = struct {
    /// The piece's first column in the surface's row 0.
    column: [*]u8,
    pitch: u32,
    count: usize,
    /// The surface's row less this is the row in the destination
    /// rectangle's coordinates.
    dy: i32,
    picture: [*]const u8,
    picture_pitch: u32,
    /// The part of the picture taken, and where all of it lands.
    src: Rect,
    dest: Rect,
    /// For each column of the piece.
    columns: union(enum) { between: [*]const Between, over: [*]const Over },
    land: Land,
    /// The picture's red and blue lie the other way round from the
    /// surface's.
    swap: bool,

    pub fn band(job: *const Smooth, lo: u32, hi: u32) void {
        switch (job.columns) {
            .between => |columns| job.mixed(lo, hi, columns),
            .over => |stretches| job.averaged(lo, hi, stretches),
        }
    }

    fn line(job: *const Smooth, y: usize) [*]const u32 {
        return @ptrCast(@alignCast(job.picture + y * job.picture_pitch));
    }

    fn out(job: *const Smooth, row: u32) []u32 {
        const first: [*]u32 = @ptrCast(@alignCast(job.column + @as(usize, row) * job.pitch));
        return first[0..job.count];
    }

    /// Rows `lo` to `hi`, each pixel mixed from the four round its place.
    fn mixed(job: *const Smooth, lo: u32, hi: u32, columns: [*]const Between) void {
        @setRuntimeSafety(false);
        var row = lo;
        while (row < hi) : (row += 1) {
            const y = @as(i32, @intCast(row)) - job.dy;
            const down = between(_blit.sourceOf(y, job.dest.min_y, job.dest.height(), job.src.min_y, job.src.height()), job.src.min_y, job.src.max_y);
            const top = job.line(down.first);
            const bottom = job.line(down.second);
            const wy = down.weight;
            for (job.out(row), columns[0..job.count]) |*pixel, column| {
                const wx = column.weight;
                job.put(pixel, sample(
                    .{ top[column.first], top[column.second], bottom[column.first], bottom[column.second] },
                    .{ (256 - wx) * (256 - wy), wx * (256 - wy), (256 - wx) * wy, wx * wy },
                ));
            }
        }
    }

    /// Rows `lo` to `hi`, each pixel the mean of the source it covers.
    fn averaged(job: *const Smooth, lo: u32, hi: u32, stretches: [*]const Over) void {
        @setRuntimeSafety(false);
        var row = lo;
        while (row < hi) : (row += 1) {
            const y = @as(i32, @intCast(row)) - job.dy;
            const down = Over.of(_blit.spanOf(y, job.dest.min_y, job.dest.height(), job.src.min_y, job.src.height()), job.src.min_y, job.src.max_y);
            for (job.out(row), stretches[0..job.count]) |*pixel, across| job.put(pixel, job.mean(across, down));
        }
    }

    /// Every pixel in the two stretches, by how much of it lies in them,
    /// each channel added and divided by the sum of the shares, rounded.
    fn mean(job: *const Smooth, across: Over, down: Over) u32 {
        var sums: [4]u64 = @splat(0);
        var total: u64 = 0;
        var y = down.first;
        while (y <= down.last) : (y += 1) {
            const weight_y = down.span.share(y);
            if (weight_y == 0) continue;
            const from = job.line(@intCast(y));
            var row: [4]u64 = @splat(0);
            var row_total: u64 = 0;
            var x = across.first;
            while (x <= across.last) : (x += 1) {
                const weight_x = across.span.share(x);
                const pixel = from[@intCast(x)];
                inline for (&row, 0..) |*channel, i| channel.* += (pixel >> (i * 8) & 0xFF) * weight_x;
                row_total += weight_x;
            }
            for (&sums, row) |*sum, part| sum.* += part * weight_y;
            total += row_total * weight_y;
        }
        if (total == 0) return 0;
        var pen: u32 = 0;
        inline for (sums, 0..) |sum, i| pen |= @as(u32, @intCast((sum + total / 2) / total)) << (i * 8);
        return pen;
    }

    inline fn put(job: *const Smooth, pixel: *u32, sampled: u32) void {
        const pen = if (job.swap) swapped(sampled) else sampled;
        if (job.land == .store) {
            pixel.* = pen;
            return;
        }
        const alpha = pen >> 24;
        if (alpha == 0xFF) {
            pixel.* = pen;
        } else if (alpha != 0) {
            pixel.* = drawing.Mix.of(pen).over(pixel.*);
        }
    }
};

/// Four pixels mixed by their weights, which make 65536: each channel the
/// weighted sum, rounded - two channels at a time, a word each.
inline fn sample(corners: [4]u32, weights: [4]u32) u32 {
    var blue_red: u64 = 0;
    var green_alpha: u64 = 0;
    inline for (corners, weights) |corner, weight| {
        blue_red += ((corner & 0xFF) | @as(u64, corner >> 16 & 0xFF) << 32) * weight;
        green_alpha += ((corner >> 8 & 0xFF) | @as(u64, corner >> 24) << 32) * weight;
    }
    const half = 32768;
    const blue: u32 = @intCast(((blue_red & 0xFFFF_FFFF) + half) >> 16);
    const red: u32 = @intCast(((blue_red >> 32) + half) >> 16);
    const green: u32 = @intCast(((green_alpha & 0xFFFF_FFFF) + half) >> 16);
    const alpha: u32 = @intCast(((green_alpha >> 32) + half) >> 16);
    return alpha << 24 | red << 16 | green << 8 | blue;
}

/// A pixel of 32 bits with its red and blue swapped: `bgra32` made
/// `rgba32`, or back.
inline fn swapped(pen: u32) u32 {
    return pen & 0xFF00_FF00 | (pen >> 16 & 0xFF) | (pen & 0xFF) << 16;
}

/// Whether a picture or a surface is one this draws: 32 bits a pixel
/// with the alpha in the top byte, `bgra32` or `rgba32`, every row
/// aligned for a word.
fn words(pixels: [*]const u8, pitch: u32, format: rtg.bitmaps.PixelFormat) bool {
    return (format == .bgra32 or format == .rgba32) and @intFromPtr(pixels) % 4 == 0 and pitch % 4 == 0;
}

/// One piece of a smooth scale between two surfaces of 32 bits a pixel,
/// each `bgra32` or `rgba32`.
///
/// INPUTS:
/// - `gb` - the library, for exec's memory and workers.
/// - `piece` - the piece being written: its rectangle inside `dest_area`.
/// - `pixels` - the picture's first byte.
/// - `pitch` - bytes from one of its rows to the next.
/// - `format` - its format.
/// - `src_area` - the part of it taken, inside the picture.
/// - `dest_area` - where all of it lands, in the RastPort's coordinates.
/// - `land` - how each pixel lands.
///
/// RESULT:
/// True when the piece is drawn. False for another pair of formats, a
/// row that is not aligned, or no memory for the columns: nothing is
/// drawn then, and the caller draws it a pixel at a time.
pub fn smooth(gb: *GraphicsBase, piece: drawing.Piece, pixels: [*]const u8, pitch: u32, format: rtg.bitmaps.PixelFormat, src_area: Rect, dest_area: Rect, land: Land) bool {
    const surface = piece.surface;
    if (!words(pixels, pitch, format) or !words(surface.pixels orelse return false, surface.pitch, surface.format)) return false;
    const sys = gb.sys_base;
    const count: usize = @intCast(piece.rect.width());
    // Made smaller either way, each pixel is the mean of what it covers.
    const shrinks = src_area.width() > dest_area.width() or src_area.height() > dest_area.height();
    const entry: usize = if (shrinks) @sizeOf(Over) else @sizeOf(Between);
    const table = sys.AllocVec(count * entry, exec.MEMF_ANY) orelse return false;
    defer sys.FreeVec(table);
    const columns: @FieldType(Smooth, "columns") = if (shrinks) over: {
        const stretches: [*]Over = @ptrCast(@alignCast(table));
        for (stretches[0..count], 0..) |*stretch, i| {
            const x = piece.rect.min_x + @as(i32, @intCast(i));
            stretch.* = Over.of(_blit.spanOf(x, dest_area.min_x, dest_area.width(), src_area.min_x, src_area.width()), src_area.min_x, src_area.max_x);
        }
        break :over .{ .over = stretches };
    } else mixed: {
        const mixed: [*]Between = @ptrCast(@alignCast(table));
        for (mixed[0..count], 0..) |*column, i| {
            const x = piece.rect.min_x + @as(i32, @intCast(i));
            column.* = between(_blit.sourceOf(x, dest_area.min_x, dest_area.width(), src_area.min_x, src_area.width()), src_area.min_x, src_area.max_x);
        }
        break :mixed .{ .between = mixed };
    };
    const on = piece.on(piece.rect);
    const job = Smooth{
        .column = surface.pixels.? + @as(usize, @intCast(on.min_x)) * 4,
        .pitch = surface.pitch,
        .count = count,
        .dy = piece.dy,
        .picture = pixels,
        .picture_pitch = pitch,
        .src = src_area,
        .dest = dest_area,
        .columns = columns,
        .land = land,
        .swap = format != surface.format,
    };
    // Made smaller, the work is the picture's pixels, not the piece's.
    const drawn = _blit.pixelsOf(on) * 4;
    const read = _blit.pixelsOf(src_area) * _blit.pixelsOf(on) / _blit.pixelsOf(dest_area);
    bands.share(sys, Smooth, &job, bands.Rows.of(@intCast(on.min_y), @intCast(on.max_y), surface.pitch), if (shrinks) @max(drawn, read) else drawn);
    return true;
}
