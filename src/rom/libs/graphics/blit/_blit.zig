// SPDX-License-Identifier: MPL-2.0
//! The blits: moving shapes rather than colours.
//!
//! Three of them, and they are the three things a window system does all
//! day. **A template** is a shape one bit to a pixel, stencilled onto the
//! surface in the pens - a letter, an icon, a pointer. **A pattern** is a
//! small tile repeated across a rectangle - the grey of a desktop, the
//! hatching of a disabled thing. **A mask** is a blit that leaves some
//! pixels alone - a shape moved over a background it does not cover.
//!
//! All three pass through to the board's engine where there is one. rtg
//! declared `blit_template` and `blit_pattern` from the start and nothing
//! had ever called them; this is what they were for.
//!
//! **The draw mode says what a clear bit means**, so a caller does not
//! pass flags for it: under `DRMD_JAM1` a clear bit leaves the surface
//! alone, under `DRMD_JAM2` it takes the background pen, and
//! `DRMD_INVERSVID` swaps set and clear. That is the same rule the line
//! pattern follows, which is the point - a shape and a dotted line are the
//! same idea at different sizes.
//!
//! A pattern is anchored to the **surface** and not to the rectangle, so
//! two rectangles filled with one pattern line up where they meet. A
//! desktop repainted in pieces is why that matters.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const Rect = graphics.Rect;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
pub const RastPort = rastport.RastPort;
const drawing = @import("../draw/_draw.zig");
const rows = @import("../rows/_rows.zig");

/// One bit out of a row of bits, the leftmost in the highest bit of the
/// first byte - the order a shape is written down in and the order the
/// engines take.
///
/// INPUTS:
/// - `bits` - the shape.
/// - `pitch` - bytes from one row to the next.
/// - `x` - the bit's column.
/// - `y` - its row.
pub fn bitAt(bits: [*]const u8, pitch: u32, x: i32, y: i32) bool {
    const row = bits + @as(usize, @intCast(y)) * pitch;
    const byte = row[@as(usize, @intCast(x)) >> 3];
    return byte >> @intCast(7 - (@as(u3, @intCast(@as(usize, @intCast(x)) & 7)))) & 1 != 0;
}

/// What the draw mode makes of a clear bit, for the engines' flags.
///
/// INPUTS:
/// - `rp` - the RastPort. Its draw mode decides.
pub fn shapeFlags(rp: *const RastPort) u32 {
    var flags: u32 = 0;
    // JAM1 is "ink only": a clear bit is left alone.
    if (rp.draw_mode & graphics.DRMD_JAM2 == 0) flags |= rtg.bitmaps.RTGTF_TRANSPARENT;
    if (rp.draw_mode & graphics.DRMD_INVERSVID != 0) flags |= rtg.bitmaps.RTGTF_INVERT;
    return flags;
}

/// Whether the engine may be asked. It writes the two colours it is given
/// and nothing else, so a mode that inverts the destination or composes a
/// coverage has to be done here.
///
/// INPUTS:
/// - `rp` - the RastPort. Its draw mode and pens decide.
/// - `piece` - where it would draw.
pub fn engineUsable(rp: *const RastPort, piece: drawing.Piece) bool {
    if (piece.bitmap == null) return false;
    if (rp.draw_mode & graphics.DRMD_COMPLEMENT != 0) return false;
    if (rp.draw_mode & graphics.DRMD_BLEND != 0) return false;
    if (!graphics.penIsOpaque(rp.fg_pen)) return false;
    if (rp.draw_mode & graphics.DRMD_JAM2 != 0 and !graphics.penIsOpaque(rp.bg_pen)) return false;
    return true;
}

/// The engine's scale, for a RastPort that wants it smooth and shows the
/// whole destination as one piece of a board's buffer: the engine mixes
/// neighbouring pixels, which is what smooth asks for. True when the
/// board did it; the caller hands the rows on.
///
/// INPUTS:
/// - `gb` - the library, for rtg.library's engine.
/// - `rp` - the RastPort.
/// - `pixels` - the picture, as rtg.library reads it; its corner is the
///   source rectangle's.
/// - `src_area` - the part of the picture scaled.
/// - `dest_area` - where it lands, in the RastPort's coordinates.
pub fn scaleByEngine(gb: *GraphicsBase, rp: *RastPort, pixels: *const rtg.RtgPixels, src_area: Rect, dest_area: Rect) bool {
    if (!rp.smooth) return false;
    var it = drawing.visible(rp, dest_area);
    const piece = it.next() orelse return false;
    if (it.next() != null) return false;
    // Cut by the clip, the picture would have to start between pixels.
    if (piece.rect.min_x != dest_area.min_x or piece.rect.min_y != dest_area.min_y or
        piece.rect.max_x != dest_area.max_x or piece.rect.max_y != dest_area.max_y) return false;
    const bitmap = piece.bitmap orelse return false;
    const target = asRtgRect(piece.on(piece.rect));
    return gb.rtg_base.ScalePixels(bitmap, &target, pixels, @intCast(src_area.width()), @intCast(src_area.height())) == rtg.errors.RTGERR_OK;
}

/// A rectangle in rtg.library's form: corner and size.
///
/// INPUTS:
/// - `r` - the rectangle, half-open.
pub fn asRtgRect(r: Rect) rtg.RtgRect {
    return .{ .x = r.min_x, .y = r.min_y, .width = r.width(), .height = r.height() };
}

/// Put one pixel of a shape down, or leave it alone.
///
/// INPUTS:
/// - `rp` - the RastPort.
/// - `p` - the piece being written: its rectangle, surface and offset.
/// - `x` - the column, in the RastPort's coordinates.
/// - `y` - the row.
/// - `set` - whether the shape's bit there is set.
pub fn stencil(rp: *RastPort, p: drawing.Piece, x: i32, y: i32, set: bool) void {
    const lit = if (rp.draw_mode & graphics.DRMD_INVERSVID != 0) !set else set;
    if (lit) {
        drawing.plot(rp, p, x, y);
    } else if (rp.draw_mode & graphics.DRMD_JAM2 != 0) {
        drawing.plotBack(rp, p, x, y);
    }
}

/// What a shape's set bits and its clear bits put down - the pens as
/// `stencil` chooses them, each ready for a run of pixels - or null where
/// a bit leaves the pixel alone.
pub const Stencil = struct {
    set: ?drawing.Brush,
    clear: ?drawing.Brush,
    /// Bytes a pixel takes.
    bytes: u32,

    /// The pens of this RastPort's mode on a surface of `format`.
    ///
    /// INPUTS:
    /// - `rp` - the RastPort. Its pens and draw mode decide.
    /// - `format` - the surface's format.
    pub fn of(rp: *const RastPort, format: rtg.bitmaps.PixelFormat) Stencil {
        const inverse = rp.draw_mode & graphics.DRMD_INVERSVID != 0;
        const jam2 = rp.draw_mode & graphics.DRMD_JAM2 != 0;
        const fore = drawing.Brush.either(rp, format, false);
        const back: ?drawing.Brush = if (jam2) drawing.Brush.either(rp, format, true) else null;
        return .{
            .set = if (inverse) back else fore,
            .clear = if (inverse) fore else back,
            .bytes = fore.bytes,
        };
    }

    /// The pixel at `at`, for a bit.
    inline fn put(s: *const Stencil, comptime T: type, at: [*]u8, set: bool) void {
        if (set) {
            if (s.set) |*pen| pen.putAs(T, at);
        } else if (s.clear) |*pen| pen.putAs(T, at);
    }

    /// `count` pixels from `to`, one for each bit of `line` from bit
    /// `first` on: a row of a shape. A byte of clear bits that put nothing
    /// down is passed over whole, which is most of a line of text.
    ///
    /// INPUTS:
    /// - `s` - the pens.
    /// - `to` - the first pixel.
    /// - `line` - the shape's row of bits.
    /// - `first` - the bit the row starts at.
    /// - `count` - how many pixels.
    pub fn row(s: *const Stencil, to: [*]u8, line: [*]const u8, first: usize, count: usize) void {
        const pen = if (s.set) |*p| p else &s.clear.?;
        switch (pen.widthAt(to, s.bytes)) {
            inline else => |width| s.rowAs(width.Type(), to, line, first, count),
        }
    }

    fn rowAs(s: *const Stencil, comptime T: type, to: [*]u8, line: [*]const u8, first: usize, count: usize) void {
        @setRuntimeSafety(false);
        var at = to;
        var col = first;
        var left = count;
        while (left != 0) {
            const skip: u3 = @intCast(col % 8);
            const n = @min(8 - @as(usize, skip), left);
            var bits = line[col / 8] << skip;
            if (bits == 0 and s.clear == null) {
                at += n * s.bytes;
            } else {
                for (0..n) |_| {
                    s.put(T, at, bits & 0x80 != 0);
                    bits <<= 1;
                    at += s.bytes;
                }
            }
            col += n;
            left -= n;
        }
    }

    /// `count` pixels from `to`, one for each bit of a tile's row from bit
    /// `first` on, the row starting over every `width` bits: a row of a
    /// pattern.
    pub fn tiled(s: *const Stencil, to: [*]u8, line: [*]const u8, first: u32, width: u32, count: usize) void {
        const pen = if (s.set) |*p| p else &s.clear.?;
        switch (pen.widthAt(to, s.bytes)) {
            inline else => |w| s.tiledAs(w.Type(), to, line, first, width, count),
        }
    }

    fn tiledAs(s: *const Stencil, comptime T: type, to: [*]u8, line: [*]const u8, first: u32, width: u32, count: usize) void {
        @setRuntimeSafety(false);
        var at = to;
        var col = first;
        for (0..count) |_| {
            s.put(T, at, line[col >> 3] >> @intCast(7 - (col & 7)) & 1 != 0);
            at += s.bytes;
            col += 1;
            if (col == width) col = 0;
        }
    }
};

/// A shape over one piece, a row at a time.
///
/// INPUTS:
/// - `rp` - the RastPort.
/// - `r` - the piece being written.
/// - `bits` - the shape.
/// - `pitch` - bytes from one of its rows to the next.
/// - `from_x` - the shape's column that lands on the piece's left.
/// - `from_y` - its row that lands on the piece's top.
pub fn templateRows(rp: *const RastPort, r: drawing.Piece, bits: [*]const u8, pitch: u32, from_x: i32, from_y: i32) void {
    const pens = Stencil.of(rp, r.surface.format);
    const width: usize = @intCast(r.rect.width());
    var y: i32 = r.rect.min_y;
    while (y < r.rect.max_y) : (y += 1) {
        const line = bits + @as(usize, @intCast(from_y + (y - r.rect.min_y))) * pitch;
        pens.row(drawing.address(r, r.rect.min_x, y), line, @intCast(from_x), width);
    }
}

/// A pattern over one piece: the tile's column stepped along the row
/// rather than worked out with a division for each pixel.
///
/// INPUTS:
/// - `rp` - the RastPort.
/// - `r` - the piece being filled.
/// - `bits` - the tile.
/// - `pitch` - bytes from one row of it to the next.
/// - `width` - how wide the tile is.
/// - `height` - how tall.
pub fn patternRows(rp: *const RastPort, r: drawing.Piece, bits: [*]const u8, pitch: u32, width: u32, height: u32) void {
    const pens = Stencil.of(rp, r.surface.format);
    // Where the pattern is anchored is the surface's origin, not the
    // RastPort's, so it is the same tiling either way in and the two
    // rectangles of one pattern still line up.
    const first_col: u32 = @intCast(@mod(r.rect.min_x + r.dx, @as(i32, @intCast(width))));
    const count: usize = @intCast(r.rect.width());
    var y: i32 = r.rect.min_y;
    while (y < r.rect.max_y) : (y += 1) {
        const tile_row: usize = @intCast(@mod(y + r.dy, @as(i32, @intCast(height))));
        pens.tiled(drawing.address(r, r.rect.min_x, y), bits + tile_row * pitch, first_col, width, count);
    }
}

/// How many bytes one pixel of a surface takes.
///
/// INPUTS:
/// - `surface` - the surface.
pub fn pixelBytes(surface: *const rtg.Surface) u32 {
    return @max(rtg.bitmaps.formatBits(surface.format) / 8, 1);
}

/// One pixel from a surface to a RastPort, both in one format.
///
/// INPUTS:
/// - `src` - the surface the pixel comes from.
/// - `p` - the piece being written: its rectangle, surface and offset.
/// - `sx` - the source pixel's column.
/// - `sy` - its row.
/// - `dx` - the destination pixel's column.
/// - `dy` - its row.
fn copyFrom(src: *const rtg.Surface, p: drawing.Piece, sx: i32, sy: i32, dx: i32, dy: i32) void {
    const bytes = pixelBytes(src);
    const at = src.pixels.? + @as(usize, @intCast(sy)) * src.pitch + @as(usize, @intCast(sx)) * bytes;
    const to = p.surface.pixels.? + @as(usize, @intCast(dy + p.dy)) * p.surface.pitch +
        @as(usize, @intCast(dx + p.dx)) * bytes;
    rows.store(to, bytes, rows.load(at, bytes));
}

/// What BltBitMapRastPort and BltMaskBitMapRastPort both do, with the mask
/// left out of the first.
///
/// INPUTS:
/// - `gb` - the library, to hand the rows on.
/// - `src` - where the pixels come from.
/// - `src_x` - the rectangle's left edge in it.
/// - `src_y` - its top edge.
/// - `dest` - the RastPort they go to.
/// - `dest_x` - where the left edge lands.
/// - `dest_y` - where the top edge lands.
/// - `width` - how wide the rectangle is.
/// - `height` - how tall.
/// - `mask` - one bit to a pixel, or null for every pixel.
/// - `mask_pitch` - bytes from one row of the mask to the next.
pub fn blitInto(
    gb: *GraphicsBase,
    src: *const rtg.Surface,
    src_x: i32,
    src_y: i32,
    dest: *RastPort,
    dest_x: i32,
    dest_y: i32,
    width: i32,
    height: i32,
    mask: ?[*]const u8,
    mask_pitch: u32,
) void {
    dest.last_error = graphics.GERR_OK;
    if (src.format != dest.surface.format) {
        dest.last_error = graphics.GERR_BAD_FORMAT;
        return;
    }
    // A surface with no pixels has nothing to copy from. Nothing here
    // makes one, so being handed one means something further back went
    // wrong; the blit says so and draws nothing, rather than faulting and
    // taking down whichever task was drawing - which, for the one that
    // reads input, is every window on the display at once.
    if (src.pixels == null) {
        dest.last_error = graphics.GERR_BAD_SIZE;
        exec.kprintf(gb.sys_base, "blit: source surface 0x%x has no pixels\n", .{@as(u32, @truncate(@intFromPtr(src)))});
        return;
    }
    const asked = Rect{ .min_x = src_x, .min_y = src_y, .max_x = src_x + width, .max_y = src_y + height };
    const from = Rect.intersect(asked, .{
        .min_x = 0,
        .min_y = 0,
        .max_x = @intCast(src.width),
        .max_y = @intCast(src.height),
    });
    if (from.isEmpty()) return;

    const dx = dest_x - src_x;
    const dy = dest_y - src_y;
    const request = from.offset(dx, dy);
    var it = drawing.visible(dest, request);
    var bound = Rect{};
    var any = false;
    const inverse = dest.draw_mode & graphics.DRMD_INVERSVID != 0;
    // The source as rtg.library reads it, for a board's engine: only its
    // surface is looked at, so plain memory serves as well as a board's.
    var described = rtg.bitmaps.RtgBitMap{
        .pixels = src.pixels,
        .width = src.width,
        .height = src.height,
        .pitch = src.pitch,
        .size_bytes = src.size_bytes,
        .format = src.format,
        .flags = src.flags,
    };

    while (it.next()) |r| {
        // The same for a piece with nowhere to put pixels: it is passed
        // over, and the pieces that do have somewhere are still drawn.
        if (r.surface.pixels == null) {
            dest.last_error = graphics.GERR_BAD_SIZE;
            exec.kprintf(gb.sys_base, "blit: clip piece surface 0x%x has no pixels\n", .{@as(u32, @truncate(@intFromPtr(r.surface)))});
            continue;
        }
        // A plain move of a piece of a board's buffer is the engine's
        // copy where it takes it; the rows it wrote are handed on below
        // with the rest.
        if (mask == null) {
            if (r.bitmap) |bitmap| {
                const copy = rtg.RtgCopy{
                    .src_x = r.rect.min_x - dx,
                    .src_y = r.rect.min_y - dy,
                    .width = r.rect.width(),
                    .height = r.rect.height(),
                    .dest_x = r.rect.min_x + r.dx,
                    .dest_y = r.rect.min_y + r.dy,
                };
                if (gb.rtg_base.CopyRect(&described, bitmap, &copy) == rtg.errors.RTGERR_OK) {
                    drawing.grow(&bound, r.rect.min_y, &any);
                    drawing.grow(&bound, r.rect.max_y - 1, &any);
                    continue;
                }
            }
        }
        // A surface moved over itself has to be walked away from where it
        // is going, or it would read pixels it has already written - the
        // reason a memmove exists. Which surface this is depends on the
        // piece, so the question is asked per piece. Where the pixels go
        // is asked on the surface itself: a row `y` of the destination is
        // the surface's row `y + r.dy`, and it is read from the source's
        // row `y - dy`. `dy` alone is not the answer - the destination is
        // counted in the RastPort and the source in the surface, and a
        // window's RastPort starts wherever the window is.
        const same = src.pixels.? == r.surface.pixels.?;
        const back_rows = same and r.dy + dy > 0;
        const back_cols = same and r.dx + dx > 0;

        var i: i32 = 0;
        while (i < r.rect.height()) : (i += 1) {
            const y = if (back_rows) r.rect.max_y - 1 - i else r.rect.min_y + i;
            if (mask == null) {
                // No mask is a plain move of a row, whichever way round the
                // overlap wants it.
                const bytes = pixelBytes(src);
                const run: usize = @as(usize, @intCast(r.rect.width())) * bytes;
                const to = r.surface.pixels.? + @as(usize, @intCast(y + r.dy)) * r.surface.pitch +
                    @as(usize, @intCast(r.rect.min_x + r.dx)) * bytes;
                const at = src.pixels.? + @as(usize, @intCast(y - dy)) * src.pitch +
                    @as(usize, @intCast(r.rect.min_x - dx)) * bytes;
                if (back_cols) rows.copyBack(to, at, run) else rows.copy(to, at, run);
                drawing.grow(&bound, y, &any);
                continue;
            }
            var j: i32 = 0;
            while (j < r.rect.width()) : (j += 1) {
                const x = if (back_cols) r.rect.max_x - 1 - j else r.rect.min_x + j;
                const sx = x - dx;
                const sy = y - dy;
                if (mask) |bits| {
                    // Read from the source's corner, so the mask travels
                    // with the shape rather than with where it lands.
                    const set = bitAt(bits, mask_pitch, sx - src_x, sy - src_y);
                    if (if (inverse) set else !set) continue;
                }
                copyFrom(src, r, sx, sy, x, y);
            }
            drawing.grow(&bound, y, &any);
        }
    }
    if (any) drawing.handOn(gb, dest, drawing.written(request, bound));
}

// --- pixels laid over what is already there ---------------------------------

/// A pen laid over the pixel at `to`, by the pen's own coverage: the two
/// mixed channel by channel, so a half-covered red over white is pink.
///
/// It is here because two calls need it - a picture put down at its own
/// size and one put down scaled - and both must mix exactly alike, or the
/// same picture drawn the two ways would not match.
pub fn blendPixel(to: [*]u8, to_bytes: u32, to_format: rtg.bitmaps.PixelFormat, pen: graphics.Pen) void {
    const alpha = pen >> 24;
    if (alpha == 0) return;
    if (alpha == 0xFF) {
        rows.store(to, to_bytes, rastport.packPen(to_format, pen) orelse 0);
        return;
    }
    const under = rastport.unpackPen(to_format, rows.load(to, to_bytes));
    // Rounded, so that full coverage of a colour lands on that colour and
    // no coverage leaves what was there untouched.
    rows.store(to, to_bytes, rastport.packPen(to_format, drawing.Mix.of(pen).over(under)) orelse 0);
}

/// A row of a picture laid over a row of a surface, each pixel by its own
/// coverage, as `blendPixel` lays it. The pairs of formats pictures and
/// displays use go with both formats known and a whole pixel a load; any
/// other pair a pixel at a time through `blendPixel`.
///
/// INPUTS:
/// - `to` - the surface's row.
/// - `to_format` - the surface's format.
/// - `from` - the picture's row.
/// - `from_format` - the picture's format.
/// - `count` - how many pixels.
pub fn blendRow(to: [*]u8, to_format: rtg.bitmaps.PixelFormat, from: [*]const u8, from_format: rtg.bitmaps.PixelFormat, count: usize) void {
    inline for (.{ .bgra32, .rgb565 }) |dest| {
        inline for (.{ .rgba32, .bgra32 }) |source| {
            const D = if (dest == .bgra32) u32 else u16;
            if (to_format == dest and from_format == source and
                @intFromPtr(to) % @sizeOf(D) == 0 and @intFromPtr(from) % 4 == 0)
            {
                return blendRowAs(dest, source, @ptrCast(@alignCast(to)), @ptrCast(@alignCast(from)), count);
            }
        }
    }
    const to_bytes = @max(rtg.bitmaps.formatBits(to_format) / 8, 1);
    const from_bytes = @max(rtg.bitmaps.formatBits(from_format) / 8, 1);
    for (0..count) |i| {
        const pen = rastport.unpackPen(from_format, rows.load(from + i * from_bytes, from_bytes));
        blendPixel(to + i * to_bytes, to_bytes, to_format, pen);
    }
}

fn blendRowAs(
    comptime dest: rtg.bitmaps.PixelFormat,
    comptime source: rtg.bitmaps.PixelFormat,
    to: [*]if (dest == .bgra32) u32 else u16,
    from: [*]const u32,
    count: usize,
) void {
    @setRuntimeSafety(false);
    for (to[0..count], from[0..count]) |*pixel, colour| {
        const pen = @call(.always_inline, rastport.unpackPen, .{ source, colour });
        const alpha = pen >> 24;
        if (alpha == 0) continue;
        const mixed = if (alpha == 0xFF) pen else drawing.Mix.of(pen).over(@call(.always_inline, rastport.unpackPen, .{ dest, pixel.* }));
        pixel.* = @truncate(@call(.always_inline, rastport.packPen, .{ dest, mixed }).?);
    }
}

// --- sampling between pixels ------------------------------------------------

/// The colour a picture has at a place between its pixels: the four
/// pixels round it mixed by how near each is, every channel and the alpha
/// alike. What a scale into a smooth RastPort takes for each pixel instead
/// of the nearest one where the picture is made larger, so it is soft
/// rather than blocky; one made smaller takes `sampleOver`.
///
/// INPUTS:
/// - `pixels` - the picture's first byte.
/// - `pitch` - bytes from one of its rows to the next.
/// - `format` - its pixel format.
/// - `area` - the part of it being taken: nothing outside it is read, its
///   edge pixels standing in for whatever is past them.
/// - `fx` - where across, in 256ths of a pixel, from the picture's left.
/// - `fy` - where down, the same.
pub fn sampleBetween(pixels: [*]const u8, pitch: u32, format: rtg.bitmaps.PixelFormat, area: Rect, fx: i64, fy: i64) graphics.Pen {
    const bytes = @max(rtg.bitmaps.formatBits(format) / 8, 1);
    const x0: i32 = @intCast(@max(@min(@divFloor(fx, 256), area.max_x - 1), area.min_x));
    const y0: i32 = @intCast(@max(@min(@divFloor(fy, 256), area.max_y - 1), area.min_y));
    const x1 = @min(x0 + 1, area.max_x - 1);
    const y1 = @min(y0 + 1, area.max_y - 1);
    const wx: u32 = @intCast(@max(@min(fx - @as(i64, x0) * 256, 255), 0));
    const wy: u32 = @intCast(@max(@min(fy - @as(i64, y0) * 256, 255), 0));
    const at = struct {
        fn pen(p: [*]const u8, pp: u32, f: rtg.bitmaps.PixelFormat, b: u32, x: i32, y: i32) graphics.Pen {
            const where = p + @as(usize, @intCast(y)) * pp + @as(usize, @intCast(x)) * b;
            return rastport.unpackPen(f, drawing.getPixel(where, b));
        }
    }.pen;
    const corners = [4]graphics.Pen{
        at(pixels, pitch, format, bytes, x0, y0),
        at(pixels, pitch, format, bytes, x1, y0),
        at(pixels, pitch, format, bytes, x0, y1),
        at(pixels, pitch, format, bytes, x1, y1),
    };
    const weights = [4]u32{ (256 - wx) * (256 - wy), wx * (256 - wy), (256 - wx) * wy, wx * wy };
    var mixed: graphics.Pen = 0;
    var shift: u5 = 0;
    while (true) : (shift += 8) {
        var sum: u32 = 0;
        for (corners, weights) |c, w| sum += ((c >> shift) & 0xFF) * w;
        mixed |= ((sum + 32768) >> 16) << shift;
        if (shift == 24) break;
    }
    return mixed;
}

/// Where the middle of a destination pixel falls in the source, in 256ths
/// of a source pixel: the two lined up by their edges, so a picture
/// scaled to a size and back lands where it started.
pub fn sourceOf(dest: i32, dest_start: i32, dest_size: i32, src_start: i32, src_size: i32) i64 {
    const offset: i64 = @as(i64, dest - dest_start) * 2 + 1;
    return @as(i64, src_start) * 256 + @divFloor(offset * src_size * 256, 2 * @as(i64, dest_size)) - 128;
}

// --- the mean of what a pixel covers -----------------------------------------

/// A stretch of a picture along one axis, from `from` up to `to`, in
/// 256ths of a pixel with a pixel's middle at its whole number - so pixel
/// `s` reaches from `s * 256 - 128` up to `s * 256 + 128`.
pub const Span = struct {
    from: i64,
    to: i64,

    /// How much of pixel `s` lies in the stretch, in 256ths.
    pub fn share(span: Span, s: i32) u64 {
        const middle = @as(i64, s) * 256;
        const lo = @max(span.from, middle - 128);
        const hi = @min(span.to, middle + 128);
        return if (hi > lo) @intCast(hi - lo) else 0;
    }

    /// The first pixel some of which lies in it.
    pub fn first(span: Span) i32 {
        return @intCast(@divFloor(span.from + 128, 256));
    }

    /// The last.
    pub fn last(span: Span) i32 {
        return @intCast(@divFloor(span.to + 127, 256));
    }
};

/// The stretch of the source a destination pixel takes along one axis of
/// a smooth scale. Where the picture is made smaller along it, it is the
/// destination pixel's own part of the source, the two lined up by their
/// edges as `sourceOf` lines them up: every source pixel counts, by how
/// much of it the destination pixel covers. Elsewhere it is a source
/// pixel's width round where the destination pixel's middle falls, which
/// takes the two pixels either side by how near each is, as
/// `sampleBetween` does.
pub fn spanOf(dest: i32, dest_start: i32, dest_size: i32, src_start: i32, src_size: i32) Span {
    if (src_size <= dest_size) {
        const middle = sourceOf(dest, dest_start, dest_size, src_start, src_size);
        return .{ .from = middle - 128, .to = middle + 128 };
    }
    const offset: i64 = dest - dest_start;
    const start = @as(i64, src_start) * 256 - 128;
    return .{
        .from = start + @divFloor(offset * src_size * 256, dest_size),
        .to = start + @divFloor((offset + 1) * src_size * 256, dest_size),
    };
}

/// The colour of a picture over `across` by `down`: every pixel of it
/// inside `area` that lies in the two stretches, each by how much of it
/// does, every channel and the alpha alike, added and divided by the sum
/// of the shares, rounded. What a smooth scale takes for each pixel where
/// the picture is made smaller, so that nothing of it is skipped: a
/// thin line or a fine pattern turns into its share of the colour rather
/// than coming and going with where the pixels fall. Made no smaller
/// either way, it is what `sampleBetween` answers.
///
/// INPUTS:
/// - `pixels` - the picture's first byte.
/// - `pitch` - bytes from one of its rows to the next.
/// - `format` - its pixel format.
/// - `area` - the part of it being taken: nothing outside it is read or
///   counted.
/// - `across` - the stretch across, from `spanOf`.
/// - `down` - the stretch down.
pub fn sampleOver(pixels: [*]const u8, pitch: u32, format: rtg.bitmaps.PixelFormat, area: Rect, across: Span, down: Span) graphics.Pen {
    const bytes = @max(rtg.bitmaps.formatBits(format) / 8, 1);
    const first_x = @max(across.first(), area.min_x);
    const last_x = @min(across.last(), area.max_x - 1);
    const first_y = @max(down.first(), area.min_y);
    const last_y = @min(down.last(), area.max_y - 1);
    var sums: [4]u64 = @splat(0);
    var total: u64 = 0;
    var y = first_y;
    while (y <= last_y) : (y += 1) {
        const weight_y = down.share(y);
        if (weight_y == 0) continue;
        const line = pixels + @as(usize, @intCast(y)) * pitch;
        var row: [4]u64 = @splat(0);
        var row_total: u64 = 0;
        var x = first_x;
        while (x <= last_x) : (x += 1) {
            const weight_x = across.share(x);
            const pen = rastport.unpackPen(format, drawing.getPixel(line + @as(usize, @intCast(x)) * bytes, bytes));
            for (&row, 0..) |*channel, i| channel.* += (pen >> @intCast(i * 8) & 0xFF) * weight_x;
            row_total += weight_x;
        }
        for (&sums, row) |*sum, part| sum.* += part * weight_y;
        total += row_total * weight_y;
    }
    if (total == 0) return 0;
    var mixed: graphics.Pen = 0;
    for (sums, 0..) |sum, i| mixed |= @as(graphics.Pen, @intCast((sum + total / 2) / total)) << @intCast(i * 8);
    return mixed;
}
