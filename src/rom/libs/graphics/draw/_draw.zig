// SPDX-License-Identifier: MPL-2.0
//! The drawing calls, and the one path they all take to get to pixels.
//!
//! Every drawing call goes through `Visible`, which hands back the
//! rectangles of what was asked for that may actually be written: the
//! rectangle clipped to the surface, then to the RastPort's clip. Today
//! that is one rectangle. When a RastPort can carry a region it will be
//! several, and nothing that uses the iterator changes - which is why the
//! iterator exists before there is anything to iterate.
//!
//! Below that there are two ways to the pixels, and which one is taken is
//! decided by the pen's alpha rather than by anything a caller asks for. A
//! board's engine takes one colour word and writes it - `FillRect` has
//! nowhere to put a coverage - so an **opaque** pen can be handed to the
//! board, and anything less has to be read, composed and written back, a
//! pixel at a time, here. A board with no engine at all answers
//! RTGERR_NOT_SUPPORTED and lands in the same software path, which is what
//! the emulator's display and the panel both do today.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const PixelFormat = rtg.bitmaps.PixelFormat;
const RtgBitMap = rtg.RtgBitMap;
const Rect = graphics.Rect;
const Pen = graphics.Pen;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const regions = @import("../region/_region.zig");
const rows = @import("../rows/_rows.zig");
pub const RastPort = rastport.RastPort;

/// One place a drawing call may write. It lives with the RastPort,
/// which caches the last one a point landed in.
pub const Piece = rastport.Piece;

/// The parts of `area` that may be written, and where each of them goes.
///
/// One piece on the RastPort's own surface when there is no clip beyond
/// the rectangle; one per region rectangle when a clip region narrows it;
/// and one per clip target, each with its own surface and offset, when
/// something manages this RastPort's pixels for it. A caller loops until
/// it hands back null and never asks how many there were.
pub const Visible = struct {
    /// What is left of the caller's rectangle after the clip rectangle.
    /// Everything handed back is inside this.
    within: Rect,
    /// The RastPort's own surface, which the first two modes write to.
    surface: *rtg.Surface,
    bitmap: ?*rtg.bitmaps.RtgBitMap,
    /// Where the walk has got to.
    at_rect: ?*regions.RegionRect,
    at_target: ?*graphics.ClipTarget,
    /// Which of the three this is. **Not** worked out from the two
    /// pointers being null: a list walked to the end also has a null one,
    /// and taking "finished" for "no clip" would hand back the whole
    /// rectangle unclipped after having just clipped it.
    mode: enum { whole, region, targets },
    done: bool = false,

    /// The next piece to write, or null when there are none.
    ///
    /// INPUTS:
    /// - `it` - the walk.
    pub fn next(it: *Visible) ?Piece {
        if (it.within.isEmpty()) return null;
        switch (it.mode) {
            .whole => {
                if (it.done) return null;
                it.done = true;
                return it.own(it.within);
            },
            .region => {
                // Where each of the region's rectangles meets what is
                // left. They never overlap, so no pixel is written twice.
                while (it.at_rect) |r| {
                    const meet = Rect.intersect(it.within, r.bounds);
                    it.at_rect = r.next;
                    if (!meet.isEmpty()) return it.own(meet);
                }
                return null;
            },
            .targets => {
                // The same, except that each piece says where it goes.
                while (it.at_target) |t| {
                    const meet = Rect.intersect(it.within, t.rect);
                    it.at_target = t.next;
                    if (!meet.isEmpty()) return .{
                        .rect = meet,
                        .surface = t.surface,
                        .bitmap = t.bitmap,
                        .dx = t.dx,
                        .dy = t.dy,
                    };
                }
                return null;
            },
        }
    }

    /// A piece on the RastPort's own surface, at its own coordinates.
    ///
    /// INPUTS:
    /// - `it` - the walk, which knows the surface.
    /// - `r` - the piece's rectangle.
    inline fn own(it: *const Visible, r: Rect) Piece {
        return .{ .rect = r, .surface = it.surface, .bitmap = it.bitmap, .dx = 0, .dy = 0 };
    }
};

/// What of `area` this RastPort is allowed to write, and where it goes.
///
/// INPUTS:
/// - `rp` - the RastPort, whose clip is already inside its surface.
/// - `area` - what the caller asked for, in the RastPort's coordinates.
///
/// RESULT:
/// An iterator, which may hand back nothing at all when the two do not
/// meet. That is not an error: a rectangle entirely off the surface is a
/// drawing call that draws nothing.
pub fn visible(rp: *const RastPort, area: Rect) Visible {
    var it = Visible{
        .within = Rect.intersect(area, rp.clip),
        .surface = rp.surface,
        .bitmap = rp.bitmap,
        .at_rect = null,
        .at_target = null,
        .mode = .whole,
    };
    // A clip list is consulted instead of a clip region, not as well as
    // one: whatever built the list has already folded the caller's own
    // clip into it, because only it knows which pieces went where.
    if (rp.clip_list) |list| {
        it.mode = .targets;
        it.at_target = list;
    } else if (rp.clip_region) |region| {
        it.mode = .region;
        it.at_rect = region.head;
    }
    return it;
}

/// Bytes a pixel takes in this format, which is also how far apart two are.
///
/// INPUTS:
/// - `format` - the surface's format.
pub fn pixelBytes(format: PixelFormat) u32 {
    return @max(rtg.bitmaps.formatBits(format) / 8, 1);
}

/// Write one pixel, already packed into the surface's format.
///
/// INPUTS:
/// - `at` - where the pixel is.
/// - `bytes` - how many bytes a pixel takes.
/// - `value` - the pixel, in the surface's format, right-aligned.
fn putPixel(at: [*]u8, bytes: u32, value: u32) void {
    // Little-endian, low bytes first, which is the order the formats are
    // named in and the order a display reads them back.
    var i: u32 = 0;
    while (i < bytes) : (i += 1) at[i] = @truncate(value >> @intCast(i * 8));
}

/// Read one pixel, still in the surface's format.
///
/// INPUTS:
/// - `at` - where the pixel is.
/// - `bytes` - how many bytes a pixel takes.
pub fn getPixel(at: [*]const u8, bytes: u32) u32 {
    var value: u32 = 0;
    var i: u32 = 0;
    while (i < bytes) : (i += 1) value |= @as(u32, at[i]) << @intCast(i * 8);
    return value;
}

/// `src` over `dst`, both 0xAARRGGBB, by src's alpha.
///
/// The usual over operator with the result left opaque: what is in a
/// surface is what is on the glass, so it covers whatever is under it
/// whatever the pen's own coverage was.
///
/// INPUTS:
/// - `src` - the colour laid on top.
/// - `dst` - the colour under it.
pub fn over(src: Pen, dst: Pen) Pen {
    const a: u32 = src >> 24 & 0xFF;
    if (a == 0xFF) return src;
    if (a == 0) return dst;
    const inv = 255 - a;
    // Rounded rather than truncated, so a pen at full alpha over anything
    // is exactly the pen and a run of composites does not drift dark.
    const r = (((src >> 16 & 0xFF) * a) + ((dst >> 16 & 0xFF) * inv) + 127) / 255;
    const g = (((src >> 8 & 0xFF) * a) + ((dst >> 8 & 0xFF) * inv) + 127) / 255;
    const b = (((src & 0xFF) * a) + ((dst & 0xFF) * inv) + 127) / 255;
    return graphics.penARGB(0xFF, @truncate(r), @truncate(g), @truncate(b));
}

/// Fill one rectangle in software, a row at a time.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: it only writes the caller's buffer, but it is unbounded
///   work and has no business in one.
/// - Forbid: not held. Nothing here is shared.
/// - Process: a Task will do.
///
/// INPUTS:
/// - `rp` - the RastPort. Its pen and draw mode decide the result.
/// - `p` - the piece being written: its rectangle, surface and offset.
pub fn fillSoftware(rp: *RastPort, p: Piece) void {
    const area = p.rect;
    // A fill is solid: the line pattern is a property of a line, and a
    // filled rectangle is not one. Which pen it uses still follows
    // DRMD_INVERSVID, so an inverted fill is the background colour.
    const inverse = rp.draw_mode & graphics.DRMD_INVERSVID != 0;

    // A fill that only writes its pen - no inverting, nothing to compose -
    // is the same packed pixel down every row, so it goes a row at a time.
    const pen = if (inverse) rp.bg_pen else rp.fg_pen;
    const composes = rp.draw_mode & graphics.DRMD_BLEND != 0 and !graphics.penIsOpaque(pen);
    if (rp.draw_mode & graphics.DRMD_COMPLEMENT == 0 and !composes) {
        const surface = p.surface;
        const bytes = pixelBytes(surface.format);
        const value = if (inverse) rp.bg_packed else rp.fg_packed;
        const count: usize = @intCast(area.width());
        var row: i32 = area.min_y;
        while (row < area.max_y) : (row += 1) {
            const at = surface.pixels.? + @as(usize, @intCast(row + p.dy)) * surface.pitch +
                @as(usize, @intCast(area.min_x + p.dx)) * bytes;
            rows.fill(at, bytes, count, value);
        }
        return;
    }

    var y: i32 = area.min_y;
    while (y < area.max_y) : (y += 1) {
        var x: i32 = area.min_x;
        while (x < area.max_x) : (x += 1) {
            if (inverse) plotBack(rp, p, x, y) else plot(rp, p, x, y);
        }
    }
}

/// The board's engine, if this rectangle can go to it.
///
/// RESULT:
/// True when the board drew it. False for every other reason there is -
/// no board behind the surface, a pen that is not opaque, a board with no
/// engine, or an engine that refused this format - and the caller then
/// does it in software. None of those is an error worth reporting: they
/// are all "not that way, then".
///
/// INPUTS:
/// - `gb` - the library, for rtg.library's engine.
/// - `rp` - the RastPort.
/// - `p` - the piece being written: its rectangle, surface and offset.
pub fn fillByEngine(gb: *GraphicsBase, rp: *RastPort, p: Piece) bool {
    const bitmap = p.bitmap orelse return false;
    // An engine writes one colour word over a rectangle. It cannot invert
    // what is there, cannot compose a coverage, and does not know which of
    // two pens a mode meant - so anything but a plain opaque fill is done
    // here instead.
    if (rp.draw_mode & (graphics.DRMD_COMPLEMENT | graphics.DRMD_INVERSVID) != 0) return false;
    if (!graphics.penIsOpaque(rp.fg_pen)) return false;
    // The engine works on the surface, so the piece is moved onto it
    // first - for a window that is where the window sits on the display.
    const on = p.on(p.rect);
    const r = rtg.RtgRect{
        .x = on.min_x,
        .y = on.min_y,
        .width = on.width(),
        .height = on.height(),
    };
    return gb.rtg_base.FillRect(bitmap, &r, rp.fg_packed) == rtg.errors.RTGERR_OK;
}

/// One pixel in one of the pens, honouring the draw mode. The caller has
/// checked that it is inside the surface.
///
/// This is the one place a pixel is written, so the modes are decided here
/// once and every primitive gets them: `DRMD_COMPLEMENT` inverts what is
/// there instead of writing, and `DRMD_BLEND` composes by the pen's alpha
/// rather than writing it. Which pen arrives is the caller's business -
/// `DRMD_JAM2` and `DRMD_INVERSVID` are decided before this is called,
/// because they are about *which* pen rather than how it lands.
///
/// INPUTS:
/// - `rp` - the RastPort. Its draw mode decides how the pixel lands.
/// - `p` - the piece being written: its rectangle, surface and offset.
/// - `x` - the column, in the RastPort's coordinates.
/// - `y` - the row.
/// - `pen` - the colour, 0xAARRGGBB.
/// - `packed_pen` - the same colour in the surface's format.
fn plotPen(rp: *RastPort, p: Piece, x: i32, y: i32, pen: graphics.Pen, packed_pen: u32) void {
    const surface = p.surface;
    const bytes = pixelBytes(surface.format);
    const at = surface.pixels.? + @as(usize, @intCast(y + p.dy)) * surface.pitch +
        @as(usize, @intCast(x + p.dx)) * bytes;

    if (rp.draw_mode & graphics.DRMD_COMPLEMENT != 0) {
        // Everything the format holds is flipped, so drawing twice puts it
        // back exactly - which is the whole use of it.
        const mask: u32 = if (bytes >= 4) 0xFFFF_FFFF else (@as(u32, 1) << @intCast(bytes * 8)) - 1;
        putPixel(at, bytes, getPixel(at, bytes) ^ mask);
        return;
    }
    if (rp.draw_mode & graphics.DRMD_BLEND != 0 and !graphics.penIsOpaque(pen)) {
        const under = rastport.unpackPen(surface.format, getPixel(at, bytes));
        const mixed = over(pen, under);
        putPixel(at, bytes, rastport.packPen(surface.format, mixed) orelse packed_pen);
        return;
    }
    putPixel(at, bytes, packed_pen);
}

/// One pixel in the foreground pen.
///
/// INPUTS:
/// - `rp` - the RastPort.
/// - `p` - the piece being written: its rectangle, surface and offset.
/// - `x` - the column, in the RastPort's coordinates.
/// - `y` - the row.
pub fn plot(rp: *RastPort, p: Piece, x: i32, y: i32) void {
    plotPen(rp, p, x, y, rp.fg_pen, rp.fg_packed);
}

/// One pixel in the background pen.
///
/// INPUTS:
/// - `rp` - the RastPort.
/// - `p` - the piece being written: its rectangle, surface and offset.
/// - `x` - the column, in the RastPort's coordinates.
/// - `y` - the row.
pub fn plotBack(rp: *RastPort, p: Piece, x: i32, y: i32) void {
    plotPen(rp, p, x, y, rp.bg_pen, rp.bg_packed);
}

/// Whether the pattern says to draw here, and which pen if so.
///
/// The bit decides the pen and `DRMD_INVERSVID` swaps the two, so the
/// pattern and the mode meet in one place. A bit that is clear draws
/// nothing at all under `DRMD_JAM1`, which is what makes a dotted line
/// dotted rather than two-coloured.
const Ink = enum { foreground, background, nothing };

/// Whether the line pattern says to draw here, and which pen if so.
///
/// INPUTS:
/// - `rp` - the RastPort. Its pattern and draw mode decide.
/// - `step` - how far along the pattern the pixel is.
fn inkAt(rp: *RastPort, step: u32) Ink {
    const bit = rp.line_pattern >> @intCast(15 - step % 16) & 1;
    const set = if (rp.draw_mode & graphics.DRMD_INVERSVID != 0) bit == 0 else bit != 0;
    if (set) return .foreground;
    return if (rp.draw_mode & graphics.DRMD_JAM2 != 0) .background else .nothing;
}

/// One pixel of a patterned run: the `step`th since the pattern began.
///
/// INPUTS:
/// - `rp` - the RastPort.
/// - `p` - the piece being written: its rectangle, surface and offset.
/// - `x` - the column, in the RastPort's coordinates.
/// - `y` - the row.
/// - `step` - how far along the pattern the pixel is.
pub fn plotPatterned(rp: *RastPort, p: Piece, x: i32, y: i32, step: u32) void {
    switch (inkAt(rp, step)) {
        .foreground => plot(rp, p, x, y),
        .background => plotBack(rp, p, x, y),
        .nothing => {},
    }
}

/// Where a point lies relative to a rectangle, as the four edges it is
/// outside of. Zero is inside.
const outside_left: u4 = 1;
const outside_right: u4 = 2;
const outside_above: u4 = 4;
const outside_below: u4 = 8;

/// Where a point lies against a rectangle: the edges it is outside of,
/// as bits, and 0 when it is inside.
///
/// INPUTS:
/// - `r` - the rectangle.
/// - `x` - the point's column.
/// - `y` - its row.
fn outcode(r: Rect, x: i32, y: i32) u4 {
    var code: u4 = 0;
    if (x < r.min_x) code |= outside_left;
    if (x >= r.max_x) code |= outside_right;
    if (y < r.min_y) code |= outside_above;
    if (y >= r.max_y) code |= outside_below;
    return code;
}

/// The part of the segment that lies inside `r`, or null if none of it
/// does.
///
/// The ends are moved onto the rectangle's edges before anything is drawn,
/// rather than the whole line being walked and each pixel tested. A line
/// mostly off the surface then costs nothing, which matters once a window
/// can be dragged half off the screen. The rectangle is half-open, so the
/// last pixel inside is at `max - 1`.
///
/// INPUTS:
/// - `r` - the rectangle, half-open.
/// - `x0` - the first end's column.
/// - `y0` - its row.
/// - `x1` - the other end's column.
/// - `y1` - its row.
pub fn clipSegment(r: Rect, x0: i32, y0: i32, x1: i32, y1: i32) ?[4]i32 {
    var ax = x0;
    var ay = y0;
    var bx = x1;
    var by = y1;
    var a = outcode(r, ax, ay);
    var b = outcode(r, bx, by);

    while (true) {
        if (a | b == 0) return .{ ax, ay, bx, by };
        if (a & b != 0) return null;

        const out = if (a != 0) a else b;
        var nx: i32 = 0;
        var ny: i32 = 0;
        if (out & outside_below != 0) {
            ny = r.max_y - 1;
            nx = ax + @divTrunc((bx - ax) * (ny - ay), by - ay);
        } else if (out & outside_above != 0) {
            ny = r.min_y;
            nx = ax + @divTrunc((bx - ax) * (ny - ay), by - ay);
        } else if (out & outside_right != 0) {
            nx = r.max_x - 1;
            ny = ay + @divTrunc((by - ay) * (nx - ax), bx - ax);
        } else {
            nx = r.min_x;
            ny = ay + @divTrunc((by - ay) * (nx - ax), bx - ax);
        }

        if (out == a) {
            ax = nx;
            ay = ny;
            a = outcode(r, ax, ay);
        } else {
            bx = nx;
            by = ny;
            b = outcode(r, bx, by);
        }
    }
}

/// A line between two points that are both inside the surface.
///
/// `step` is how far along the pattern it starts, so a line clipped into
/// several pieces keeps one pattern across all of them rather than
/// restarting at each edge.
///
/// INPUTS:
/// - `rp` - the RastPort.
/// - `p` - the piece being written: its rectangle, surface and offset.
/// - `x0` - the first end's column.
/// - `y0` - its row.
/// - `x1` - the other end's column.
/// - `y1` - its row.
/// - `step` - how far along the line pattern it is, moved on here.
pub fn line(rp: *RastPort, p: Piece, x0: i32, y0: i32, x1: i32, y1: i32, step: *u32) void {
    var x = x0;
    var y = y0;
    const dx = @abs(x1 - x0);
    const dy = @abs(y1 - y0);
    const step_x: i32 = if (x1 > x0) 1 else -1;
    const step_y: i32 = if (y1 > y0) 1 else -1;
    var err: i32 = @as(i32, @intCast(dx)) - @as(i32, @intCast(dy));

    while (true) {
        plotPatterned(rp, p, x, y, step.*);
        step.* +%= 1;
        if (x == x1 and y == y1) break;
        const e2 = err * 2;
        if (e2 > -@as(i32, @intCast(dy))) {
            err -= @intCast(dy);
            x += step_x;
        }
        if (e2 < @as(i32, @intCast(dx))) {
            err += @intCast(dx);
            y += step_y;
        }
    }
}

/// A run of pixels along one row or one column, patterned and clipped.
///
/// Every primitive that is made of straight edges comes through here, so
/// the pattern advances the same way for all of them and the clipping is
/// written once.
///
/// INPUTS:
/// - `gb` - the library, to hand the rows on.
/// - `rp` - the RastPort.
/// - `from` - the run, as a rectangle one pixel thick.
/// - `horizontal` - whether it runs along a row rather than down a column.
pub fn span(gb: *GraphicsBase, rp: *RastPort, from: Rect, horizontal: bool) void {
    var step: u32 = rp.pattern_step;
    var it = visible(rp, from);
    var top: i32 = 0;
    var end: i32 = 0;
    var any = false;
    while (it.next()) |r| {
        // The pattern counts from the start of the run, not from where the
        // clip let it begin, or a run cut in two would be dotted wrongly.
        if (horizontal) {
            var x: i32 = r.rect.min_x;
            while (x < r.rect.max_x) : (x += 1) {
                var y: i32 = r.rect.min_y;
                while (y < r.rect.max_y) : (y += 1) {
                    plotPatterned(rp, r, x, y, step +% @as(u32, @intCast(x - from.min_x)));
                }
            }
        } else {
            var y: i32 = r.rect.min_y;
            while (y < r.rect.max_y) : (y += 1) {
                var x: i32 = r.rect.min_x;
                while (x < r.rect.max_x) : (x += 1) {
                    plotPatterned(rp, r, x, y, step +% @as(u32, @intCast(y - from.min_y)));
                }
            }
        }
        if (!any) {
            top = r.rect.min_y;
            end = r.rect.max_y;
            any = true;
        } else {
            top = @min(top, r.rect.min_y);
            end = @max(end, r.rect.max_y);
        }
    }
    const run: u32 = @intCast(if (horizontal) from.width() else from.height());
    step +%= run;
    rp.pattern_step = step;
    if (any) handOn(gb, rp, top, end);
}

/// One row of a solid fill, clipped, with the rows it touched noted.
///
/// The area calls fill a shape a scanline at a time and hand the whole of
/// it on once at the end, so they need a fill that clips but does not
/// refresh. RectFill's row loop is the same thing with the rows known in
/// advance.
///
/// INPUTS:
/// - `rp` - the RastPort.
/// - `x0` - where the row starts.
/// - `x1` - one past where it ends.
/// - `y` - the row.
/// - `bound` - the rows written so far, widened here.
/// - `any` - whether anything was written, set here.
pub fn fillSpan(rp: *RastPort, x0: i32, x1: i32, y: i32, bound: *Rect, any: *bool) void {
    if (x1 <= x0) return;
    const inverse = rp.draw_mode & graphics.DRMD_INVERSVID != 0;
    var it = visible(rp, .{ .min_x = x0, .min_y = y, .max_x = x1, .max_y = y + 1 });
    while (it.next()) |r| {
        var x: i32 = r.rect.min_x;
        while (x < r.rect.max_x) : (x += 1) {
            if (inverse) plotBack(rp, r, x, y) else plot(rp, r, x, y);
        }
        grow(bound, y, any);
    }
}

/// Plot the eight points a circle's symmetry gives at once.
///
/// INPUTS:
/// - `rp` - the RastPort.
/// - `cx` - the centre's column.
/// - `cy` - the centre's row.
/// - `x` - the point's offset across, in the octant being walked.
/// - `y` - its offset down.
/// - `step` - how far along the line pattern it is, moved on here.
/// - `bound` - the rows written so far, widened here.
/// - `any` - whether anything was written, set here.
pub fn circlePoints(rp: *RastPort, cx: i32, cy: i32, x: i32, y: i32, step: *u32, bound: *Rect, any: *bool) void {
    const at = [_][2]i32{
        .{ cx + x, cy + y }, .{ cx - x, cy + y }, .{ cx + x, cy - y }, .{ cx - x, cy - y },
        .{ cx + y, cy + x }, .{ cx - y, cy + x }, .{ cx + y, cy - x }, .{ cx - y, cy - x },
    };
    for (at) |point| {
        const piece = pieceAt(rp, point[0], point[1]) orelse continue;
        plotPatterned(rp, piece, point[0], point[1], step.*);
        step.* +%= 1;
        grow(bound, point[1], any);
    }
}

/// Whether a point is somewhere this RastPort may write.
///
/// INPUTS:
/// - `rp` - the RastPort.
/// - `x` - the column, in the RastPort's coordinates.
/// - `y` - the row.
pub fn pieceAt(rp: *RastPort, x: i32, y: i32) ?Piece {
    if (!rp.clip.contains(x, y)) return null;

    // The last piece a point landed in, tried first. A curve is walked a
    // point at a time and consecutive points are next to each other, so
    // the answer is almost always the one before - which turns a walk of
    // every piece into one comparison. The cache holds a rectangle the
    // point must be inside, never a wider one, so a hit cannot be wrong;
    // it is dropped whenever the clipping changes.
    if (rp.last_piece.rect.contains(x, y)) return rp.last_piece;

    if (rp.clip_list) |list| {
        var at: ?*graphics.ClipTarget = list;
        while (at) |t| : (at = t.next) {
            if (t.rect.contains(x, y)) {
                const piece = Piece{
                    .rect = Rect.intersect(t.rect, rp.clip),
                    .surface = t.surface,
                    .bitmap = t.bitmap,
                    .dx = t.dx,
                    .dy = t.dy,
                };
                rp.last_piece = piece;
                return piece;
            }
        }
        return null;
    }

    if (rp.clip_region) |region| {
        // The rectangle that matched and not the whole clip, so that what
        // is remembered is a place the answer holds for.
        var at = region.head;
        while (at) |r| : (at = r.next) {
            if (r.bounds.contains(x, y)) {
                const piece = Piece{
                    .rect = Rect.intersect(r.bounds, rp.clip),
                    .surface = rp.surface,
                    .bitmap = rp.bitmap,
                    .dx = 0,
                    .dy = 0,
                };
                rp.last_piece = piece;
                return piece;
            }
        }
        return null;
    }

    const piece = Piece{ .rect = rp.clip, .surface = rp.surface, .bitmap = rp.bitmap, .dx = 0, .dy = 0 };
    rp.last_piece = piece;
    return piece;
}

/// Widen the range of rows that will be handed on.
///
/// INPUTS:
/// - `bound` - the rows written so far, widened here to take `y`.
/// - `any` - whether anything was written, set here.
/// - `y` - a row just written.
pub fn grow(bound: *Rect, y: i32, any: *bool) void {
    if (!any.*) {
        bound.min_y = y;
        bound.max_y = y + 1;
        any.* = true;
    } else {
        bound.min_y = @min(bound.min_y, y);
        bound.max_y = @max(bound.max_y, y + 1);
    }
}

/// The four points an ellipse's symmetry gives at once.
///
/// INPUTS:
/// - `rp` - the RastPort.
/// - `cx` - the centre's column.
/// - `cy` - the centre's row.
/// - `x` - the point's offset across, in the quarter being walked.
/// - `y` - its offset down.
/// - `step` - how far along the line pattern it is, moved on here.
/// - `bound` - the rows written so far, widened here.
/// - `any` - whether anything was written, set here.
pub fn ellipsePoints(rp: *RastPort, cx: i32, cy: i32, x: i32, y: i32, step: *u32, bound: *Rect, any: *bool) void {
    const at = [_][2]i32{
        .{ cx + x, cy + y }, .{ cx - x, cy + y }, .{ cx + x, cy - y }, .{ cx - x, cy - y },
    };
    for (at) |point| {
        const piece = pieceAt(rp, point[0], point[1]) orelse continue;
        plotPatterned(rp, piece, point[0], point[1], step.*);
        step.* +%= 1;
        grow(bound, point[1], any);
    }
}

/// Sine of a whole number of degrees, scaled by 1024.
///
/// A table of a quarter turn, worked out by the compiler and stored as
/// numbers - so nothing here needs a floating-point library at run time,
/// and an arc costs a table lookup rather than a series.
pub const sine_scale: i32 = 1024;
const quarter_sine: [91]i32 = blk: {
    @setEvalBranchQuota(20_000);
    var table: [91]i32 = undefined;
    for (&table, 0..) |*entry, degrees| {
        const radians = @as(f64, @floatFromInt(degrees)) * 3.14159265358979323846 / 180.0;
        entry.* = @intFromFloat(@round(@sin(radians) * @as(f64, sine_scale)));
    }
    break :blk table;
};

/// The sine of a whole number of degrees, scaled by 1024, off the
/// quarter-turn table.
///
/// INPUTS:
/// - `degrees` - any number of them; turns are taken off.
pub fn sinDeg(degrees: i32) i32 {
    const d = @mod(degrees, 360);
    return switch (d) {
        0...90 => quarter_sine[@intCast(d)],
        91...180 => quarter_sine[@intCast(180 - d)],
        181...270 => -quarter_sine[@intCast(d - 180)],
        else => -quarter_sine[@intCast(360 - d)],
    };
}

/// The cosine of a whole number of degrees, scaled by 1024: the sine a
/// quarter turn on.
///
/// INPUTS:
/// - `degrees` - any number of them.
pub fn cosDeg(degrees: i32) i32 {
    return sinDeg(degrees + 90);
}

/// Whether the point at (dx, dy) from the centre lies in the sweep from
/// `from` to `to`, going the way the numbers increase.
///
/// Worked out with cross products against the two edges of the sweep, so
/// there is no angle to compute for the point itself - only two
/// multiplications and a comparison. A sweep of half a turn or more is the
/// two half-planes joined rather than met, which is the only case that
/// needs saying out loud.
///
/// INPUTS:
/// - `dx` - the point's offset across from the centre.
/// - `dy` - its offset up from the centre.
/// - `from` - where the sweep starts, in degrees.
/// - `to` - where it ends.
pub fn inSweep(dx: i32, dy: i32, from: i32, to: i32) bool {
    const sweep = @mod(to - from, 360);
    if (sweep == 0) return false;
    const sx = cosDeg(from);
    const sy = sinDeg(from);
    const ex = cosDeg(to);
    const ey = sinDeg(to);
    const after_start = @as(i64, sx) * dy - @as(i64, sy) * dx >= 0;
    const before_end = @as(i64, dx) * ey - @as(i64, dy) * ex >= 0;
    return if (sweep < 180) after_start and before_end else after_start or before_end;
}

/// Give the rows that were written to the display.
///
/// A buffer of a board's is only on the glass once rtg.library has been
/// told; plain memory has nobody to tell. Only the rows touched go, so a
/// small fill costs a small refresh.
///
/// INPUTS:
/// - `gb` - the library, for rtg.library.
/// - `rp` - the RastPort.
/// - `top` - the first row written.
/// - `end` - one past the last.
pub fn handOn(gb: *GraphicsBase, rp: *RastPort, top: i32, end: i32) void {
    if (end <= top) return;
    // With targets the rows went to whichever of them covers them, at that
    // target's own offset, so each is told about its own share. A target
    // that is not a board's buffer - a window's backing store - has
    // nothing to tell.
    if (rp.clip_list) |list| {
        var at: ?*graphics.ClipTarget = list;
        while (at) |t| : (at = t.next) {
            const bm = t.bitmap orelse continue;
            const lo = @max(top, t.rect.min_y);
            const hi = @min(end, t.rect.max_y);
            if (hi <= lo) continue;
            tell(gb, bm, @intCast(lo + t.dy), @intCast(hi - lo));
        }
        return;
    }
    const bitmap = rp.bitmap orelse return;
    tell(gb, bitmap, @intCast(top), @intCast(end - top));
}

/// `rows` rows from `y` of `bm` are new: handed to the display, or
/// gathered for the end of the batch that is open on it.
///
/// A batch is what `BeginDraw` opens. While one is, a row written is
/// only remembered; the display sees nothing until the last `EndDraw`
/// hands the gathered rows on in one. That is what keeps a thing drawn
/// in two steps - rubbed out, then drawn again - from ever being shown
/// half done.
fn tell(gb: *GraphicsBase, bm: *RtgBitMap, y: u32, count: u32) void {
    const end = y + count;
    // The batch is the buffer's, so every task drawing on it changes these
    // fields, each under a layer lock of its own. Read, merged and written
    // back with nothing else running, or a task set aside half way would
    // write back a span that lost another's rows.
    const flushed: ?Span = gathered: {
        gb.sys_base.Forbid();
        defer gb.sys_base.Permit();
        if (bm.held == 0) break :gathered .{ .top = y, .end = end };
        if (bm.dirty_end <= bm.dirty_top) {
            bm.dirty_top = y;
            bm.dirty_end = end;
            break :gathered null;
        }
        // What lies between two gathered pieces is sent with them, because
        // a display is told a run of rows and not a set of them. Welding a
        // piece on across a gap therefore sends every untouched row in the
        // gap as well, and a send's own cost is about one row's worth of
        // pixels - so anything past a handful of them is dearer than
        // sending what is gathered and starting again.
        const gap = if (y >= bm.dirty_end)
            y - bm.dirty_end
        else if (end <= bm.dirty_top)
            bm.dirty_top - end
        else
            0;
        if (gap > merge_gap) {
            const old: Span = .{ .top = bm.dirty_top, .end = bm.dirty_end };
            bm.dirty_top = y;
            bm.dirty_end = end;
            break :gathered old;
        }
        bm.dirty_top = @min(bm.dirty_top, y);
        bm.dirty_end = @max(bm.dirty_end, end);
        break :gathered null;
    };
    // Sent with the scheduler free again: a driver may wait on its bus.
    if (flushed) |gathered| _ = gb.rtg_base.RefreshBitMap(bm, gathered.top, gathered.end - gathered.top);
}

/// A run of rows of a buffer, `end` one past the last.
pub const Span = struct { top: u32, end: u32 };

/// The rows gathered on `bm`, taken out of it: read and cleared as one
/// step, so rows another task gathers after this are left for it rather
/// than wiped. Null when nothing is gathered. The caller holds Forbid.
pub fn takeSpan(bm: *RtgBitMap) ?Span {
    if (bm.dirty_end <= bm.dirty_top) return null;
    const taken: Span = .{ .top = bm.dirty_top, .end = bm.dirty_end };
    bm.dirty_top = 0;
    bm.dirty_end = 0;
    return taken;
}

/// The untouched rows a batch will carry rather than send what it has
/// and begin again. Small, because a row costs about what a send does:
/// what this buys is that the pieces of one small thing - something
/// rubbed out and drawn a few rows off - still go together.
const merge_gap: u32 = 8;
