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

/// Read one pixel, still in the surface's format.
///
/// INPUTS:
/// - `at` - where the pixel is.
/// - `bytes` - how many bytes a pixel takes.
pub fn getPixel(at: [*]const u8, bytes: u32) u32 {
    return rows.load(at, bytes);
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
    return Mix.of(src).over(dst);
}

/// x / 255 rounded down, for x up to 255 * 255 + 255: what every mix of
/// two colours ends in, without a division.
///
/// INPUTS:
/// - `x` - the sum.
pub inline fn div255(x: u32) u32 {
    return (x + 1 + (x >> 8)) >> 8;
}

/// The same for two values a half-word each, as red and blue lie in a
/// pixel, each up to 255 * 255 + 127 - what a mix sums to - so that
/// neither carries into the other.
///
/// INPUTS:
/// - `x` - the two sums, one in each half.
inline fn div255Pair(x: u32) u32 {
    return (x + 0x0001_0001 + (x >> 8 & 0x00FF_00FF)) >> 8 & 0x00FF_00FF;
}

/// A colour of coverage 1 to 254 to be laid over pixel after pixel, with
/// what every pixel needs of it worked out once.
///
/// Each channel is rounded, `(colour * a + under * (255 - a) + 127) /
/// 255`, which lands full coverage exactly on the colour and keeps a run
/// of composites from drifting dark. Red and blue go together in one word
/// a half-word each, so a pixel is two multiplies and two shifts rather
/// than three divisions - the same sums fbboard's engine does, so a
/// picture does not depend on which of the two laid it.
pub const Mix = struct {
    /// The colour's red and blue, a half-word each, times its alpha and
    /// 127 more.
    rb: u32,
    /// Its green, the same.
    g: u32,
    /// What is under it counts by 255 less the alpha.
    inverse: u32,

    /// What laying `pen` takes.
    ///
    /// INPUTS:
    /// - `pen` - the colour, 0xAARRGGBB, its alpha 1 to 254.
    pub fn of(pen: Pen) Mix {
        const a: u32 = pen >> 24;
        return .{
            .rb = ((pen >> 16 & 0xFF) * a + 127) << 16 | ((pen & 0xFF) * a + 127),
            .g = (pen >> 8 & 0xFF) * a + 127,
            .inverse = 255 - a,
        };
    }

    /// The colour over `under`, opaque.
    ///
    /// INPUTS:
    /// - `m` - the colour, made ready.
    /// - `under` - what is there, 0xAARRGGBB.
    pub inline fn over(m: Mix, under: Pen) Pen {
        const rb = (under & 0x00FF_00FF) * m.inverse + m.rb;
        const g = (under >> 8 & 0xFF) * m.inverse + m.g;
        return 0xFF00_0000 | div255Pair(rb) | div255(g) << 8;
    }
};

/// How a pen lands, which the draw mode decides once for a whole drawing:
/// written; the pixel turned over instead (`DRMD_COMPLEMENT`); laid over
/// it by the pen's alpha (`DRMD_BLEND`, a pen that is not opaque); or not
/// at all, a pen with no alpha laid over leaving what is there, its own
/// alpha too, as `over` leaves it.
pub const Lay = enum { put, complement, blend, none };

/// One pen ready to be written on one surface, pixel after pixel.
///
/// What `plotPen` decides for every pixel - the mode, the pixel's size,
/// the pen packed, what mixing it takes - is decided here once, so a run
/// of pixels is a loop of stores. Which pen it is (`DRMD_JAM2`,
/// `DRMD_INVERSVID`) is still the caller's business, as it is for
/// `plotPen`.
pub const Brush = struct {
    format: PixelFormat,
    bytes: u32,
    lay: Lay,
    packed_pen: u32,
    /// Only for `.blend`.
    mix: Mix,

    /// A pen as this RastPort's mode lays it on a surface of `format`.
    ///
    /// INPUTS:
    /// - `rp` - the RastPort. Its draw mode decides how the pen lands.
    /// - `format` - the surface's format.
    /// - `pen` - the colour, 0xAARRGGBB.
    /// - `packed_pen` - the same colour in that format.
    pub fn of(rp: *const RastPort, format: PixelFormat, pen: Pen, packed_pen: u32) Brush {
        const lay: Lay = if (rp.draw_mode & graphics.DRMD_COMPLEMENT != 0)
            .complement
        else if (rp.draw_mode & graphics.DRMD_BLEND != 0 and !graphics.penIsOpaque(pen))
            (if (pen >> 24 == 0) .none else .blend)
        else
            .put;
        return .{
            .format = format,
            .bytes = pixelBytes(format),
            .lay = lay,
            .packed_pen = packed_pen,
            .mix = if (lay == .blend) Mix.of(pen) else undefined,
        };
    }

    /// The foreground pen, or the background pen.
    ///
    /// INPUTS:
    /// - `rp` - the RastPort.
    /// - `format` - the surface's format.
    /// - `back` - whether it is the background pen.
    pub fn either(rp: *const RastPort, format: PixelFormat, back: bool) Brush {
        return if (back) of(rp, format, rp.bg_pen, rp.bg_packed) else of(rp, format, rp.fg_pen, rp.fg_packed);
    }

    /// The pen the line pattern's `ink` stands for, or null for none.
    ///
    /// INPUTS:
    /// - `rp` - the RastPort.
    /// - `format` - the surface's format.
    /// - `ink` - which of the pens, if any.
    pub fn inked(rp: *const RastPort, format: PixelFormat, ink: Ink) ?Brush {
        return switch (ink) {
            .foreground => either(rp, format, false),
            .background => either(rp, format, true),
            .nothing => null,
        };
    }

    /// One pixel, at `at`.
    ///
    /// INPUTS:
    /// - `b` - the pen.
    /// - `at` - where the pixel is.
    pub inline fn put(b: *const Brush, at: [*]u8) void {
        switch (b.lay) {
            .put => rows.store(at, b.bytes, b.packed_pen),
            .complement => rows.store(at, b.bytes, rows.load(at, b.bytes) ^ b.everyBit()),
            .blend => b.blendAt(at),
            .none => {},
        }
    }

    /// Every bit a pixel has: what a complement turns over.
    inline fn everyBit(b: *const Brush) u32 {
        return if (b.bytes >= 4) 0xFFFF_FFFF else (@as(u32, 1) << @intCast(b.bytes * 8)) - 1;
    }

    fn blendAt(b: *const Brush, at: [*]u8) void {
        const under = rastport.unpackPen(b.format, rows.load(at, b.bytes));
        rows.store(at, b.bytes, rastport.packPen(b.format, b.mix.over(under)) orelse b.packed_pen);
    }

    /// How a loop over pixels from `at`, `stride` bytes apart, may store
    /// them: as whole words or half-words when every one of them is
    /// aligned to its size, which a surface's pixels nearly always are, or
    /// a byte at a time. Checked once for the loop, not for each pixel.
    pub fn widthAt(b: *const Brush, at: [*]const u8, stride: usize) Width {
        const at_or_stride = @intFromPtr(at) | stride;
        if (b.bytes == 4 and at_or_stride & 3 == 0) return .word;
        if (b.bytes == 2 and at_or_stride & 1 == 0) return .half;
        return .bytes;
    }

    pub const Width = enum {
        bytes,
        half,
        word,

        pub fn Type(comptime width: Width) type {
            return switch (width) {
                .bytes => u8,
                .half => u16,
                .word => u32,
            };
        }
    };

    /// One pixel, at `at`, stored as `T` says: `u8` a byte at a time,
    /// `u16` or `u32` in one store at an address the caller has made sure
    /// is aligned.
    pub inline fn putAs(b: *const Brush, comptime T: type, at: [*]u8) void {
        @setRuntimeSafety(false);
        if (T == u8) return b.put(at);
        const pixel: *T = @ptrCast(@alignCast(at));
        switch (b.lay) {
            .put => pixel.* = @truncate(b.packed_pen),
            .complement => pixel.* = ~pixel.*,
            .blend => b.blendAt(at),
            .none => {},
        }
    }

    /// `count` pixels, `stride` bytes apart, from `at`: a row when the
    /// stride is a pixel, a column when it is the surface's pitch.
    ///
    /// INPUTS:
    /// - `b` - the pen.
    /// - `at` - the first pixel.
    /// - `stride` - bytes from one pixel to the next.
    /// - `count` - how many.
    pub fn run(b: *const Brush, at: [*]u8, stride: usize, count: usize) void {
        if (count == 0) return;
        switch (b.lay) {
            .put => if (stride == b.bytes) return rows.fill(at, b.bytes, count, b.packed_pen),
            .complement => if (stride == b.bytes) return rows.invert(at, count * b.bytes),
            .blend => return b.blendRun(at, stride, count),
            .none => return,
        }
        switch (b.widthAt(at, stride)) {
            inline else => |width| b.runAs(width.Type(), at, stride, count),
        }
    }

    fn runAs(b: *const Brush, comptime T: type, at: [*]u8, stride: usize, count: usize) void {
        @setRuntimeSafety(false);
        var to = at;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            b.putAs(T, to);
            to += stride;
        }
    }

    /// A run laid over what is there. The formats the displays use go a
    /// whole pixel at a time with the format known; the rest through the
    /// pen packed and unpacked as `plotPen` does it.
    fn blendRun(b: *const Brush, at: [*]u8, stride: usize, count: usize) void {
        @setRuntimeSafety(false);
        switch (b.format) {
            inline .bgra32, .rgb565 => |format| {
                const T = if (format == .bgra32) u32 else u16;
                if (@intFromPtr(at) % @sizeOf(T) == 0 and stride % @sizeOf(T) == 0) {
                    var to = at;
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const pixel: *T = @ptrCast(@alignCast(to));
                        const under = @call(.always_inline, rastport.unpackPen, .{ format, pixel.* });
                        pixel.* = @truncate(@call(.always_inline, rastport.packPen, .{ format, b.mix.over(under) }).?);
                        to += stride;
                    }
                    return;
                }
            },
            else => {},
        }
        var to = at;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            b.blendAt(to);
            to += stride;
        }
    }

    /// A line between two points inside the piece, every pixel of it in
    /// this pen: Bresenham's walk, the address moved with the point.
    ///
    /// INPUTS:
    /// - `b` - the pen.
    /// - `p` - the piece being written.
    /// - `x0` - the first end's column.
    /// - `y0` - its row.
    /// - `x1` - the other end's column.
    /// - `y1` - its row.
    pub fn walk(b: *const Brush, p: Piece, x0: i32, y0: i32, x1: i32, y1: i32) void {
        const at = address(p, x0, y0);
        switch (b.widthAt(at, p.surface.pitch)) {
            inline else => |width| b.walkAs(width.Type(), at, p.surface.pitch, x0, y0, x1, y1),
        }
    }

    fn walkAs(b: *const Brush, comptime T: type, first: [*]u8, pitch: usize, x0: i32, y0: i32, x1: i32, y1: i32) void {
        @setRuntimeSafety(false);
        const dx: i32 = @intCast(@abs(x1 - x0));
        const dy: i32 = @intCast(@abs(y1 - y0));
        const right = x1 > x0;
        const down = y1 > y0;
        var at = first;
        var x = x0;
        var y = y0;
        var err = dx - dy;
        while (true) {
            b.putAs(T, at);
            if (x == x1 and y == y1) break;
            const e2 = err * 2;
            if (e2 > -dy) {
                err -= dy;
                if (right) {
                    x += 1;
                    at += b.bytes;
                } else {
                    x -= 1;
                    at -= b.bytes;
                }
            }
            if (e2 < dx) {
                err += dx;
                if (down) {
                    y += 1;
                    at += pitch;
                } else {
                    y -= 1;
                    at -= pitch;
                }
            }
        }
    }
};

/// Where a pixel of a piece is in memory.
///
/// INPUTS:
/// - `p` - the piece: its surface and offset.
/// - `x` - the column, in the RastPort's coordinates.
/// - `y` - the row.
pub inline fn address(p: Piece, x: i32, y: i32) [*]u8 {
    const surface = p.surface;
    return surface.pixels.? + @as(usize, @intCast(y + p.dy)) * surface.pitch +
        @as(usize, @intCast(x + p.dx)) * pixelBytes(surface.format);
}

/// Fill one rectangle in software, a row at a time.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: it only writes the caller's buffer, but it is unbounded
///   work and has no business in one.
/// - Locks: none needed. Nothing here is shared.
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
    const brush = Brush.either(rp, p.surface.format, inverse);
    const count: usize = @intCast(area.width());
    var row: i32 = area.min_y;
    while (row < area.max_y) : (row += 1) brush.run(address(p, area.min_x, row), brush.bytes, count);
}

/// The board's engine, if this rectangle can go to it: its fill for an
/// opaque pen, its blend (`BlendRect`) for a translucent one composed
/// under `DRMD_BLEND`.
///
/// RESULT:
/// True when the board drew it. False for every other reason there is -
/// no board behind the surface, a pen that is not opaque outside
/// `DRMD_BLEND`, a board with no engine, or an engine that refused this
/// job - and the caller then does it in software. None of those is an
/// error worth reporting: they are all "not that way, then".
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
    // The engine works on the surface, so the piece is moved onto it
    // first - for a window that is where the window sits on the display.
    const on = p.on(p.rect);
    const r = rtg.RtgRect{
        .x = on.min_x,
        .y = on.min_y,
        .width = on.width(),
        .height = on.height(),
    };
    if (!graphics.penIsOpaque(rp.fg_pen)) {
        // Composed by its alpha, as plotPen composes it, or not at all.
        if (rp.draw_mode & graphics.DRMD_BLEND == 0) return false;
        return gb.rtg_base.BlendRect(bitmap, &r, rp.fg_pen) == rtg.errors.RTGERR_OK;
    }
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
    const brush = Brush.of(rp, p.surface.format, pen, packed_pen);
    brush.put(address(p, x, y));
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

/// One pixel of a colour laid over what is there by the colour's own
/// alpha, whatever the draw mode: how a glyph's coverage or a colour
/// font's palette lands. The caller has checked that it is inside the
/// surface and decided the colour, and a transparent one writes nothing.
///
/// INPUTS:
/// - `p` - the piece being written: its rectangle, surface and offset.
/// - `x` - the column, in the RastPort's coordinates.
/// - `y` - the row.
/// - `pen` - the colour, 0xAARRGGBB.
pub fn plotOver(p: Piece, x: i32, y: i32, pen: Pen) void {
    const alpha = pen >> 24;
    if (alpha == 0) return;
    const surface = p.surface;
    const bytes = pixelBytes(surface.format);
    const at = address(p, x, y);
    const mixed = if (alpha == 0xFF) pen else Mix.of(pen).over(rastport.unpackPen(surface.format, rows.load(at, bytes)));
    rows.store(at, bytes, rastport.packPen(surface.format, mixed) orelse return);
}

/// Whether the pattern says to draw here, and which pen if so.
///
/// The bit decides the pen and `DRMD_INVERSVID` swaps the two, so the
/// pattern and the mode meet in one place. A bit that is clear draws
/// nothing at all under `DRMD_JAM1`, which is what makes a dotted line
/// dotted rather than two-coloured.
pub const Ink = enum { foreground, background, nothing };

/// Whether the line pattern says to draw here, and which pen if so.
///
/// INPUTS:
/// - `rp` - the RastPort. Its pattern and draw mode decide.
/// - `step` - how far along the pattern the pixel is.
pub fn inkAt(rp: *RastPort, step: u32) Ink {
    const bit = rp.line_pattern >> @intCast(15 - step % 16) & 1;
    const set = if (rp.draw_mode & graphics.DRMD_INVERSVID != 0) bit == 0 else bit != 0;
    if (set) return .foreground;
    return if (rp.draw_mode & graphics.DRMD_JAM2 != 0) .background else .nothing;
}

/// The ink of a line pattern that is the same at every step - every bit
/// set, or none - or null for one that changes along the line.
///
/// INPUTS:
/// - `rp` - the RastPort. Its pattern and draw mode decide.
pub fn solidInk(rp: *RastPort) ?Ink {
    if (rp.line_pattern != 0xFFFF and rp.line_pattern != 0) return null;
    return inkAt(rp, 0);
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
    // A pattern that says the same everywhere is one pen for the whole
    // line, written as a run where the line is straight.
    if (solidInk(rp)) |ink| {
        const length: u32 = @max(@abs(x1 - x0), @abs(y1 - y0)) + 1;
        step.* +%= length;
        const brush = Brush.inked(rp, p.surface.format, ink) orelse return;
        if (y0 == y1) return brush.run(address(p, @min(x0, x1), y0), brush.bytes, length);
        if (x0 == x1) return brush.run(address(p, x0, @min(y0, y1)), p.surface.pitch, length);
        return brush.walk(p, x0, y0, x1, y1);
    }
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
    const solid = solidInk(rp);
    while (it.next()) |r| {
        if (solid) |ink| {
            // One pen all along: rows, or columns a pitch at a time.
            if (Brush.inked(rp, r.surface.format, ink)) |brush| {
                if (horizontal) {
                    var y: i32 = r.rect.min_y;
                    while (y < r.rect.max_y) : (y += 1) brush.run(address(r, r.rect.min_x, y), brush.bytes, @intCast(r.rect.width()));
                } else {
                    var x: i32 = r.rect.min_x;
                    while (x < r.rect.max_x) : (x += 1) brush.run(address(r, x, r.rect.min_y), r.surface.pitch, @intCast(r.rect.height()));
                }
            }
        } else if (horizontal) {
            // The pattern counts from the start of the run, not from where
            // the clip let it begin, or a run cut in two would be dotted
            // wrongly.
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
    if (any) handOn(gb, rp, .{ .min_x = from.min_x, .min_y = top, .max_x = from.max_x, .max_y = end });
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
        const brush = Brush.either(rp, r.surface.format, inverse);
        brush.run(address(r, r.rect.min_x, y), brush.bytes, @intCast(r.rect.width()));
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
    return Sweep.of(from, to).holds(dx, dy);
}

/// A sweep's two edges, worked out once for the many points a shape asks
/// about: `inSweep` without the four table lookups each time.
pub const Sweep = struct {
    sx: i32 = 0,
    sy: i32 = 0,
    ex: i32 = 0,
    ey: i32 = 0,
    /// No degrees: nothing is in it.
    empty: bool = true,
    /// Less than half a turn: the two half-planes met, not joined.
    narrow: bool = false,

    pub fn of(from: i32, to: i32) Sweep {
        const sweep = @mod(to - from, 360);
        if (sweep == 0) return .{};
        return .{ .sx = cosDeg(from), .sy = sinDeg(from), .ex = cosDeg(to), .ey = sinDeg(to), .empty = false, .narrow = sweep < 180 };
    }

    /// Whether the point at (`dx`, `dy`) from the centre is in the sweep. A
    /// sine is at most 1024, so a point nearer than `near` is asked in 32
    /// bits: each product under 2^30, their difference under 2^31.
    pub fn holds(s: Sweep, dx: i32, dy: i32) bool {
        if (s.empty) return false;
        const after_start, const before_end = if (@abs(dx) < near and @abs(dy) < near) .{
            s.sx * dy - s.sy * dx >= 0,
            dx * s.ey - dy * s.ex >= 0,
        } else .{
            @as(i64, s.sx) * dy - @as(i64, s.sy) * dx >= 0,
            @as(i64, dx) * s.ey - @as(i64, dy) * s.ex >= 0,
        };
        return if (s.narrow) after_start and before_end else after_start or before_end;
    }

    const near: u32 = 1 << 19;
};

/// Give what was written to the display.
///
/// A buffer of a board's is only on the glass once rtg.library has been
/// told; plain memory has nobody to tell. Only the rectangle touched goes,
/// so a small fill costs a small refresh.
///
/// INPUTS:
/// - `gb` - the library, for rtg.library.
/// - `rp` - the RastPort.
/// - `area` - what was written: the rows written, across the columns of
///   the request they were written for - every piece written is inside
///   those (`written`).
pub fn handOn(gb: *GraphicsBase, rp: *RastPort, area: Rect) void {
    if (area.isEmpty()) return;
    // With targets the pixels went to whichever of them covers them, at
    // that target's own offset, so each is told about its own share. A
    // target that is not a board's buffer - a window's backing store - has
    // nothing to tell.
    if (rp.clip_list) |list| {
        var at: ?*graphics.ClipTarget = list;
        while (at) |t| : (at = t.next) {
            const bm = t.bitmap orelse continue;
            const share = area.intersect(t.rect);
            if (share.isEmpty()) continue;
            tell(gb, bm, share.offset(t.dx, t.dy));
        }
        return;
    }
    const bitmap = rp.bitmap orelse return;
    const share = area.intersect(rp.clip);
    if (share.isEmpty()) return;
    tell(gb, bitmap, share);
}

/// What a primitive hands on: the rows it wrote (`bound`, grown a row at
/// a time by `grow`) across the columns of `request`, the rectangle it was
/// asked to write in.
pub fn written(request: Rect, bound: Rect) Rect {
    return .{ .min_x = request.min_x, .min_y = bound.min_y, .max_x = request.max_x, .max_y = bound.max_y };
}

/// `area` of `bm` is new: handed to the display, or gathered for the end
/// of the batch that is open on it.
///
/// A batch is what `BeginDraw` opens. While one is, what is written is
/// only remembered; the display sees nothing until the last `EndDraw`
/// hands what was gathered on in one. That is what keeps a thing drawn
/// in two steps - rubbed out, then drawn again - from ever being shown
/// half done.
fn tell(gb: *GraphicsBase, bm: *RtgBitMap, area: Rect) void {
    const given: Area = .{
        .left = @intCast(area.min_x),
        .top = @intCast(area.min_y),
        .right = @intCast(area.max_x),
        .end = @intCast(area.max_y),
    };
    // The batch is the buffer's, so every task drawing on it changes these
    // fields, each under a layer lock of its own. Read, merged and written
    // back under the batches' lock, or a task on the other core would
    // write back an area that lost another's.
    const flushed: ?Area = gathered: {
        gb.sys_base.AcquireLock(&gb.draw_lock);
        defer gb.sys_base.ReleaseLock(&gb.draw_lock);
        if (bm.held == 0) break :gathered given;
        if (bm.dirty_end <= bm.dirty_top) {
            gather(bm, given);
            break :gathered null;
        }
        // What lies between two gathered pieces is sent with them, because
        // a display is told one rectangle and not a set of them. Welding a
        // piece on across a gap therefore sends what is in the gap as
        // well, and a send's own cost is about one row's worth of pixels -
        // so anything past a handful of rows of them is dearer than
        // sending what is gathered and starting again.
        if (apart(bm, given)) {
            const old = takeArea(bm).?;
            gather(bm, given);
            break :gathered old;
        }
        bm.dirty_left = @min(bm.dirty_left, given.left);
        bm.dirty_top = @min(bm.dirty_top, given.top);
        bm.dirty_right = @max(bm.dirty_right, given.right);
        bm.dirty_end = @max(bm.dirty_end, given.end);
        break :gathered null;
    };
    // Sent with the lock let go: a driver may wait on its bus.
    if (flushed) |area_now| refresh(gb, bm, area_now);
}

/// Whether `given` is too far from what is gathered on `bm` to be sent
/// with it. The caller holds the batches' lock, and something is
/// gathered.
///
/// A board told only rows is sent whole rows, side by side or not, so
/// only the rows between the two count. One told rectangles - and a
/// watched buffer, whose hook copies what it is told - is sent the box
/// around both, so what counts is the pixels in that box that neither
/// covers: the sides of a window's frame, gathered into one box, would be
/// the whole window.
fn apart(bm: *const RtgBitMap, given: Area) bool {
    if (!byRect(bm)) {
        const gap = if (given.top >= bm.dirty_end)
            given.top - bm.dirty_end
        else if (given.end <= bm.dirty_top)
            bm.dirty_top - given.end
        else
            0;
        return gap > merge_gap;
    }
    const held: Area = .{ .left = bm.dirty_left, .top = bm.dirty_top, .right = bm.dirty_right, .end = bm.dirty_end };
    const box: Area = .{
        .left = @min(held.left, given.left),
        .top = @min(held.top, given.top),
        .right = @max(held.right, given.right),
        .end = @max(held.end, given.end),
    };
    const between = pixelsIn(box) -| (pixelsIn(held) + pixelsIn(given));
    return between > @as(u64, merge_gap) * bm.width;
}

/// Whether what is handed on from `bm` is a rectangle rather than rows:
/// its hook is told one, or its board takes one.
fn byRect(bm: *const RtgBitMap) bool {
    if (bm.watch != null) return true;
    const board: *const rtg.RtgBoard = @ptrCast(@alignCast(bm.board orelse return false));
    const ops = board.ops orelse return false;
    return ops.refresh_rect != null;
}

fn pixelsIn(area: Area) u64 {
    return @as(u64, area.right - area.left) * (area.end - area.top);
}

/// A rectangle of a buffer, `right` and `end` one past its last column
/// and row.
pub const Area = struct { left: u32, top: u32, right: u32, end: u32 };

/// `area` gathered on `bm`, where nothing is. The caller holds the
/// batches' lock.
fn gather(bm: *RtgBitMap, area: Area) void {
    bm.dirty_left = area.left;
    bm.dirty_top = area.top;
    bm.dirty_right = area.right;
    bm.dirty_end = area.end;
}

/// What is gathered on `bm`, taken out of it: read and cleared as one
/// step, so what another task gathers after this is left for it rather
/// than wiped. Null when nothing is gathered. The caller holds the
/// batches' lock (`GraphicsBase.draw_lock`).
pub fn takeArea(bm: *RtgBitMap) ?Area {
    if (bm.dirty_end <= bm.dirty_top) return null;
    const taken: Area = .{ .left = bm.dirty_left, .top = bm.dirty_top, .right = bm.dirty_right, .end = bm.dirty_end };
    bm.dirty_left = 0;
    bm.dirty_top = 0;
    bm.dirty_right = 0;
    bm.dirty_end = 0;
    return taken;
}

/// `area` of `bm` handed to the display (rtg's RefreshRect). With no lock
/// held: a driver may wait on its bus.
pub fn refresh(gb: *GraphicsBase, bm: *RtgBitMap, area: Area) void {
    _ = gb.rtg_base.RefreshRect(bm, &.{
        .x = @intCast(area.left),
        .y = @intCast(area.top),
        .width = @intCast(area.right - area.left),
        .height = @intCast(area.end - area.top),
    });
}

/// The untouched rows a batch will carry rather than send what it has
/// and begin again - for a board told rectangles, as many rows' worth of
/// untouched pixels. Small, because a row costs about what a send does:
/// what this buys is that the pieces of one small thing - something
/// rubbed out and drawn a few rows off - still go together.
const merge_gap: u32 = 8;

// --- a shape filled from a fill style ---------------------------------------

const _round = @import("_round.zig");

/// Whether a shape on this RastPort is filled from its fill style rather
/// than its pen.
pub fn styled(rp: *const RastPort) bool {
    const fill = rp.fill orelse return false;
    return fill.kind >= graphics.FILL_LINEAR and fill.kind <= graphics.FILL_TILE;
}

/// A point of the fill style, from the shape's own box to the RastPort.
fn boxPoint(box: Rect, x: i32, y: i32) [2]i64 {
    return .{
        @as(i64, box.min_x) + @divTrunc(@as(i64, x) * box.width(), graphics.FILL_ONE),
        @as(i64, box.min_y) + @divTrunc(@as(i64, y) * box.height(), graphics.FILL_ONE),
    };
}

/// The colour at `t` along a fill style's stops, 0 to FILL_ONE. Between
/// two stops every channel, alpha too, is mixed in proportion; past either
/// end the end colour carries on.
fn alongStops(fill: *const graphics.FillStyle, t: i64) Pen {
    const count: usize = @max(@min(fill.count, fill.stops.len), 1);
    const stops = fill.stops[0..count];
    if (t <= stops[0].at) return stops[0].pen;
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const a = stops[i - 1];
        const b = stops[i];
        if (t > b.at) continue;
        const between: i64 = b.at - a.at;
        if (between <= 0) return b.pen;
        const part: i64 = t - a.at;
        var mixed: Pen = 0;
        var shift: u5 = 0;
        while (true) : (shift += 8) {
            const from: i64 = (a.pen >> shift) & 0xFF;
            const to: i64 = (b.pen >> shift) & 0xFF;
            const value: u32 = @intCast(from + @divTrunc((to - from) * part, between));
            mixed |= value << shift;
            if (shift == 24) break;
        }
        return mixed;
    }
    return stops[count - 1].pen;
}

/// A 4x4 ordered dither for a surface of 16 bits a pixel: each channel
/// scaled to the surface's steps and a threshold added that differs in
/// each pixel of the four by four, so that what packing drops is dropped
/// at a different point in each and a gradient comes out smooth instead
/// of in bands. A channel is scaled to the steps a display shows, not cut
/// to its top bits: a display widens 5 or 6 bits by repeating them below
/// themselves (31 of red is 255, 16 is 132), and the pixels of a four by
/// four average to the colour as it shows them, to within one of 255.
/// The thresholds stay inside a step by as much as widening lands off its
/// middle, so a colour the surface holds exactly - 132 of red - comes out
/// as it is in every pixel. facet.library writes its 565 back the same
/// way (raster/target.zig).
const bayer = [16]u8{ 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

/// A channel of 0 to 255 times these, in 16.16, is it in steps of 31 and
/// of 63.
const to_five = 7966;
const to_six = 16190;

/// What is added before the fraction is cut, at each place of the four by
/// four: 16 thresholds spread evenly, in 16.16, over what every widened
/// colour leaves room for - q * 65536 <= widened(q) * to_five + t <
/// (q + 1) * 65536 for each step q - 7148 to 58673 of five bits, 84% of
/// a step, and 12977 to 52877 of six, 65%.
const Threshold = struct { five: u32, six: u32 };

const thresholds = thresholds: {
    var made: [16]Threshold = undefined;
    for (&made, bayer) |*threshold, order| {
        const wide: u32 = order;
        threshold.* = .{ .five = 7148 + wide * 3435, .six = 12977 + wide * 2660 };
    }
    break :thresholds made;
};

/// `pen` dithered for pixel (x, y) of a surface in `format`: each channel
/// the step it falls to there, widened again as the display widens it, so
/// that packing (`packPen`, which keeps a channel's top bits) puts down
/// that step. As it is on a surface of more bits a channel.
fn dithered(pen: Pen, x: i32, y: i32, format: PixelFormat) Pen {
    const threshold = thresholds[@as(usize, @intCast(y & 3)) * 4 + @as(usize, @intCast(x & 3))];
    const green_six = switch (format) {
        .rgb565 => true,
        .argb1555 => false,
        else => return pen,
    };
    const red = five(pen >> 16 & 0xFF, threshold);
    const green = if (green_six) six(pen >> 8 & 0xFF, threshold) else five(pen >> 8 & 0xFF, threshold);
    const blue = five(pen & 0xFF, threshold);
    return pen & 0xFF00_0000 | red << 16 | green << 8 | blue;
}

/// A channel's step of five bits at a threshold, widened to eight.
fn five(channel: u32, threshold: Threshold) u32 {
    const step = (channel * to_five + threshold.five) >> 16;
    return step << 3 | step >> 2;
}

/// A channel's step of six bits at a threshold, widened to eight.
fn six(channel: u32, threshold: Threshold) u32 {
    const step = (channel * to_six + threshold.six) >> 16;
    return step << 2 | step >> 4;
}

/// The colour a fill style gives a pixel of the shape being filled.
///
/// INPUTS:
/// - `rp` - the RastPort: its fill style, and the box the shape sits in.
/// - `x` - the pixel's column, in the RastPort's coordinates.
/// - `y` - its row.
/// - `format` - the surface it goes on, for dithering.
pub fn fillColour(rp: *const RastPort, x: i32, y: i32, format: PixelFormat) Pen {
    const fill = rp.fill orelse return rp.fg_pen;
    if (fill.kind == graphics.FILL_TILE) {
        const tile = fill.tile orelse return rp.fg_pen;
        if (tile.width == 0 or tile.height == 0) return rp.fg_pen;
        const pixels = tile.pixels orelse return rp.fg_pen;
        const bytes = pixelBytes(tile.format);
        const tx: usize = @intCast(@mod(x, @as(i32, @intCast(tile.width))));
        const ty: usize = @intCast(@mod(y, @as(i32, @intCast(tile.height))));
        return rastport.unpackPen(tile.format, getPixel(pixels + ty * tile.pitch + tx * bytes, bytes));
    }

    const from = boxPoint(rp.fill_box, fill.from_x, fill.from_y);
    const to = boxPoint(rp.fill_box, fill.to_x, fill.to_y);
    const dx = to[0] - from[0];
    const dy = to[1] - from[1];
    const px = x - from[0];
    const py = y - from[1];
    const t: i64 = if (fill.kind == graphics.FILL_RADIAL) radial: {
        const reach = _round.isqrt(@intCast(@min(dx * dx + dy * dy, 0xFFFF_FFFF)));
        if (reach == 0) break :radial graphics.FILL_ONE;
        const far = _round.isqrt(@intCast(@min(px * px + py * py, 0xFFFF_FFFF)));
        break :radial @divTrunc(@as(i64, far) * graphics.FILL_ONE, reach);
    } else linear: {
        const length = dx * dx + dy * dy;
        if (length == 0) break :linear 0;
        break :linear @divTrunc((px * dx + py * dy) * graphics.FILL_ONE, length);
    };
    const pen = alongStops(fill, t);
    if (fill.flags & graphics.FILLF_NODITHER != 0) return pen;
    return dithered(pen, x, y, format);
}

/// One pixel of a shape, from the fill style when there is one, from the
/// pen otherwise.
pub fn plotShape(rp: *RastPort, p: Piece, x: i32, y: i32) void {
    if (!styled(rp)) return plot(rp, p, x, y);
    plotOver(p, x, y, fillColour(rp, x, y, p.surface.format));
}

/// `fillSpan` for a shape: from the fill style when the RastPort has one,
/// exactly `fillSpan` when it does not. Text and lines keep `fillSpan`, so
/// a fill style never reaches them.
pub fn fillShapeSpan(rp: *RastPort, x0: i32, x1: i32, y: i32, bound: *Rect, any: *bool) void {
    if (!styled(rp)) return fillSpan(rp, x0, x1, y, bound, any);
    if (x1 <= x0) return;
    var it = visible(rp, .{ .min_x = x0, .min_y = y, .max_x = x1, .max_y = y + 1 });
    while (it.next()) |r| {
        var x: i32 = r.rect.min_x;
        while (x < r.rect.max_x) : (x += 1) plotOver(r, x, y, fillColour(rp, x, y, r.surface.format));
        grow(bound, y, any);
    }
}

/// A piece of a rectangle, from the fill style.
pub fn fillStyled(rp: *RastPort, p: Piece) void {
    var y: i32 = p.rect.min_y;
    while (y < p.rect.max_y) : (y += 1) {
        var x: i32 = p.rect.min_x;
        while (x < p.rect.max_x) : (x += 1) plotOver(p, x, y, fillColour(rp, x, y, p.surface.format));
    }
}

// --- tests (host: ./zig build test) -----------------------------------------
//
// The loops that use these are held to the pixel-at-a-time path in
// graphics.zig, where a RastPort can be made to draw with.

const testing = @import("std").testing;

test "div255 is a division by 255 for every sum a mix can make" {
    var x: u32 = 0;
    while (x <= 255 * 255 + 255) : (x += 1) try testing.expectEqual(x / 255, div255(x));
    // Two at once, neither spilling into the other, up to the most a mix
    // sums to: 255 * 255 and the 127 that rounds it.
    x = 0;
    while (x <= 255 * 255 + 127) : (x += 1) {
        const other = 255 * 255 + 127 - x;
        try testing.expectEqual((x / 255) << 16 | other / 255, div255Pair(x << 16 | other));
    }
}

test "Mix lays a colour as the sums divided by 255 lay it" {
    const slow = struct {
        fn over(src: Pen, dst: Pen) Pen {
            const a: u32 = src >> 24;
            var mixed: Pen = 0xFF00_0000;
            var shift: u5 = 0;
            while (shift < 24) : (shift += 8) {
                mixed |= (((src >> shift & 0xFF) * a + (dst >> shift & 0xFF) * (255 - a) + 127) / 255) << shift;
            }
            return mixed;
        }
    }.over;
    // Every colour over every colour under, at coverages from the ends
    // and the middle; then every coverage of every colour over a few.
    // Each channel is mixed by itself, so one value in all three of a
    // pen's channels and another in the three under it covers them.
    for ([_]u32{ 1, 2, 64, 127, 128, 200, 253, 254 }) |a| {
        for (0..256) |s| for (0..256) |d| {
            const c: u32 = @intCast(s);
            const u: u32 = @intCast(d);
            const pen = a << 24 | c << 16 | (255 - c) << 8 | c;
            const under = 0xFF00_0000 | u << 16 | u << 8 | (255 - u);
            try testing.expectEqual(slow(pen, under), over(pen, under));
        };
    }
    for (1..255) |a| for (0..256) |s| for ([_]u32{ 0, 77, 255 }) |u| {
        const c: u32 = @intCast(s);
        const pen = @as(u32, @intCast(a)) << 24 | c << 16 | c << 8 | c;
        const under = 0xFF00_0000 | u << 16 | u << 8 | u;
        try testing.expectEqual(slow(pen, under), Mix.of(pen).over(under));
    };
    // The ends are not mixed at all.
    try testing.expectEqual(@as(Pen, 0xFF12_3456), over(0xFF12_3456, 0xFF65_4321));
    try testing.expectEqual(@as(Pen, 0xFF65_4321), over(0x0012_3456, 0xFF65_4321));
}
