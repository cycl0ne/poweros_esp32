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

/// Whether every pixel a shape puts down is simply one of the two packed
/// pens - nothing inverted, nothing composed - so it can be stored without
/// going through the per-pixel path that decides those.
///
/// INPUTS:
/// - `rp` - the RastPort. Its draw mode and pens decide.
pub fn writesPensOnly(rp: *const RastPort) bool {
    if (rp.draw_mode & graphics.DRMD_COMPLEMENT != 0) return false;
    if (rp.draw_mode & graphics.DRMD_BLEND == 0) return true;
    if (!graphics.penIsOpaque(rp.fg_pen)) return false;
    return rp.draw_mode & graphics.DRMD_JAM2 == 0 or graphics.penIsOpaque(rp.bg_pen);
}

/// A pattern over one piece, when writesPensOnly says the pens can be
/// stored as they are: the tile's column stepped along the row rather than
/// worked out with a division for each pixel.
///
/// INPUTS:
/// - `rp` - the RastPort.
/// - `r` - the piece being filled.
/// - `bits` - the tile.
/// - `pitch` - bytes from one row of it to the next.
/// - `width` - how wide the tile is.
/// - `height` - how tall.
pub fn patternRows(rp: *const RastPort, r: drawing.Piece, bits: [*]const u8, pitch: u32, width: u32, height: u32) void {
    const bytes = pixelBytes(r.surface);
    const inverse = rp.draw_mode & graphics.DRMD_INVERSVID != 0;
    const jam2 = rp.draw_mode & graphics.DRMD_JAM2 != 0;
    const first_col: u32 = @intCast(@mod(r.rect.min_x + r.dx, @as(i32, @intCast(width))));
    var y: i32 = r.rect.min_y;
    while (y < r.rect.max_y) : (y += 1) {
        const tile_row: usize = @intCast(@mod(y + r.dy, @as(i32, @intCast(height))));
        const line = bits + tile_row * pitch;
        var to = r.surface.pixels.? + @as(usize, @intCast(y + r.dy)) * r.surface.pitch +
            @as(usize, @intCast(r.rect.min_x + r.dx)) * bytes;
        var col = first_col;
        var x: i32 = r.rect.min_x;
        while (x < r.rect.max_x) : (x += 1) {
            const set = line[col >> 3] >> @intCast(7 - (col & 7)) & 1 != 0;
            if (set != inverse) {
                rows.store(to, bytes, rp.fg_packed);
            } else if (jam2) {
                rows.store(to, bytes, rp.bg_packed);
            }
            to += bytes;
            col += 1;
            if (col == width) col = 0;
        }
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
    var it = drawing.visible(dest, .{
        .min_x = from.min_x + dx,
        .min_y = from.min_y + dy,
        .max_x = from.max_x + dx,
        .max_y = from.max_y + dy,
    });
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
    if (any) drawing.handOn(gb, dest, bound.min_y, bound.max_y);
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
    const under = rastport.unpackPen(to_format, drawing.getPixel(to, to_bytes));
    var mixed: graphics.Pen = 0xFF << 24;
    var shift: u5 = 0;
    while (shift < 24) : (shift += 8) {
        const over_part: u32 = (pen >> shift) & 0xFF;
        const under_part: u32 = (under >> shift) & 0xFF;
        // Rounded, so that full coverage of a colour lands on that colour
        // and no coverage leaves what was there untouched.
        mixed |= ((over_part * alpha + under_part * (255 - alpha) + 127) / 255) << shift;
    }
    rows.store(to, to_bytes, rastport.packPen(to_format, mixed) orelse 0);
}

// --- sampling between pixels ------------------------------------------------

/// The colour a picture has at a place between its pixels: the four
/// pixels round it mixed by how near each is, every channel and the alpha
/// alike. What a scale into a smooth RastPort takes for each pixel instead
/// of the nearest one, so a picture made larger is soft rather than
/// blocky and one made smaller keeps its thin lines.
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
