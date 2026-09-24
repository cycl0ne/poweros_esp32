// SPDX-License-Identifier: MPL-2.0
//! The RastPort: a surface to draw into and the state to draw it with, and
//! the View it comes from when nobody names a buffer.
//!
//! The structure is the library's alone - `sdk/libs/graphics/graphics.zig`
//! has only an opaque `RastPort`, and everything about one is reached
//! through the `RPTAG_` tags. So it can grow for as long as the system
//! does without a caller noticing.
//!
//! The View is the display: the first board rtg.library lists, normally
//! the one this library's init brought up (`display/_display.zig`). It is
//! resolved when it is used and the base is left holding the answer,
//! because a board can be deleted. What is kept is the **board**, not its
//! buffer: a board's displayed buffer can be swapped, so it is asked for
//! afresh each time.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const Surface = rtg.Surface;
const RtgBitMap = rtg.RtgBitMap;
const RtgBoard = rtg.RtgBoard;
const PixelFormat = rtg.bitmaps.PixelFormat;
const TagItem = sdk.utility.TagItem;
const Pen = graphics.Pen;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const regions = @import("../region/_region.zig");
const draw = @import("../draw/_draw.zig");
const areas = @import("../area/_area.zig");
const fonts = @import("../text/_text.zig");

/// One place a drawing call may write: what of it may be written, and
/// where those pixels go.
pub const Piece = extern struct {
    /// What may be written, **in the RastPort's coordinates**.
    rect: graphics.Rect,
    /// Where those pixels go.
    surface: *Surface,
    /// The board's buffer, when that is what this is: the drawing engine
    /// and the hand-on after a write are its. Null for plain memory.
    bitmap: ?*RtgBitMap,
    /// Added to a coordinate in the RastPort's space to reach the surface.
    dx: i32,
    dy: i32,

    /// Where `r` lands, `r` being in the RastPort's coordinates.
    ///
    /// INPUTS:
    /// - `p` - the piece.
    /// - `r` - a rectangle in the RastPort's coordinates.
    pub inline fn on(p: Piece, r: graphics.Rect) graphics.Rect {
        return r.offset(p.dx, p.dy);
    }
};

/// A RastPort, as the library holds it. A caller has an opaque pointer to
/// this and reaches every field through a tag.
pub const RastPort = extern struct {
    /// What is drawn into, always. An `RtgBitMap`'s first seven fields are
    /// a `Surface`, so a board's buffer arrives here by pointer.
    surface: *Surface,
    /// The same buffer as rtg.library knows it, when it came from a board:
    /// how the board's engine is reached and how rows are handed on. Null
    /// for plain memory, which is always drawn in software.
    bitmap: ?*RtgBitMap,
    /// 0xAARRGGBB, as the caller set them.
    fg_pen: Pen,
    bg_pen: Pen,
    /// The same two in `surface.format`, packed once when they were set so
    /// that the drawing path does no conversion.
    fg_packed: u32,
    bg_packed: u32,
    draw_mode: graphics.DrawMode,
    /// The current point, which the line and text calls draw from.
    cp_x: i32,
    cp_y: i32,
    /// What may be written, already clipped to the surface, so a clip can
    /// only ever narrow. Every drawing call goes through it; a region will
    /// replace it with a list and nothing above will notice.
    clip: graphics.Rect,
    /// A shape to clip to as well, of the caller's, or null. It narrows
    /// the clip rectangle rather than replacing it, so a drawing call is
    /// clipped to both - and the caller owns it, so a RastPort must be
    /// given another clip before the region is disposed of.
    clip_region: ?*regions.Region,
    /// Where the pixels go, when that is not simply `surface`. Whatever
    /// manages windows builds this list and owns it; with none, this
    /// RastPort has one target, its own surface at its own coordinates.
    /// A list is consulted instead of `clip_region`, not as well as it -
    /// whoever built it has already folded the caller's own clip in.
    clip_list: ?*graphics.ClipTarget,
    /// How an area of this RastPort with nothing in it yet is painted: 0
    /// for `bg_pen`, `BACKFILL_NONE` for nothing, or a `*utility.Hook`.
    /// Set by whatever manages windows; read by `EraseRect` and nothing
    /// else, which is how this library calls a window's ground back
    /// without knowing what a window is.
    backfill: usize,
    /// Where the last point that was tested landed, so the next one - which
    /// on a curve is next to it - can be answered with one comparison
    /// instead of a walk. An empty rectangle means there is nothing
    /// remembered, which is what the clipping changing leaves behind: a
    /// rectangle kept from before would then be somebody else's.
    last_piece: Piece,
    /// Which pixels along a line are drawn, sixteen bits used in turn.
    /// All ones is a solid line.
    line_pattern: u16,
    /// How far along that pattern the next pixel is. It carries on from
    /// one Draw to the next, so a shape drawn as several lines is dotted
    /// evenly round its corners rather than starting again at each.
    pattern_step: u32,
    /// Where the area calls collect a shape, taken by InitArea and given
    /// back with the RastPort. One allocation holding the corners, where
    /// each shape starts, and room to sort a row's crossings in.
    area_points: ?[*]graphics.Point,
    /// How many corners it has room for, and how many are in it.
    area_max: u32,
    area_count: u32,
    /// How many shapes have been begun since the last AreaEnd.
    area_shapes: u32,
    /// The font `Text` draws with, or null. The caller's: a font in the
    /// ROM outlives everything, and one that is not will be closed by
    /// whoever opened it.
    font: ?*fonts.TextFont,
    /// How letters are drawn on top of the font's own shape.
    text_style: graphics.FontStyle,
    /// The batch this RastPort has open (`BeginDraw`), and how deep it
    /// is nested. While one is open the rows written are gathered in the
    /// bitmap rather than handed to the display, and `EndDraw` hands on
    /// the one bitmap remembered here - not whatever the clip targets
    /// point at by then, which a retile may have changed underneath.
    draw_held: ?*RtgBitMap,
    draw_depth: u32,
    /// What the last call on this RastPort went wrong with, or GERR_OK.
    /// It lives here rather than in the base because a RastPort belongs to
    /// whoever draws with it - so two tasks drawing at once cannot
    /// overwrite one another's answer, with no lock and no per-task table.
    last_error: i32,
};

/// Write what went wrong where the caller asked for it, for the calls that
/// have no RastPort to put it in yet.
///
/// INPUTS:
/// - `gb` - the library's base, for the tag calls.
/// - `tag_list` - the caller's tags.
/// - `tag` - `RPTAG_ErrorPtr` or `BMTAG_ErrorPtr`.
/// - `code` - a GERR_ code, `GERR_OK` included: a call that worked says so,
///   so what is read belongs to the call just made.
pub fn report(gb: *GraphicsBase, tag_list: ?[*]const TagItem, tag: sdk.utility.Tag, code: i32) void {
    const at = gb.utility_base.GetTagData(tag, 0, tag_list);
    if (at != 0) @as(*i32, @ptrFromInt(at)).* = code;
}

/// A pen in a surface's format.
///
/// INPUTS:
/// - `format` - the surface's format.
/// - `pen` - 0xAARRGGBB.
///
/// RESULT:
/// The bytes to write, in the low bits of the word, or null for a format
/// this library has no mapping for. A pen is a colour, and `indexed8`
/// wants a palette to search and `gray8` and `mono1` a rule for turning a
/// colour into one; none of the three has been decided, so they are
/// refused rather than guessed at.
///
/// CONTEXT:
/// Any. It is arithmetic on its arguments.
pub fn packPen(format: PixelFormat, pen: Pen) ?u32 {
    const a: u32 = pen >> 24 & 0xFF;
    const r: u32 = pen >> 16 & 0xFF;
    const g: u32 = pen >> 8 & 0xFF;
    const b: u32 = pen & 0xFF;
    return switch (format) {
        // A 0xAARRGGBB word stored to memory on this chip is b, g, r, a.
        .bgra32 => pen,
        .rgba32 => a << 24 | b << 16 | g << 8 | r,
        .bgr24 => r << 16 | g << 8 | b,
        .rgb24 => b << 16 | g << 8 | r,
        .rgb565 => (r >> 3) << 11 | (g >> 2) << 5 | (b >> 3),
        .argb1555 => @as(u32, @intFromBool(a >= 0x80)) << 15 |
            (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3),
        .indexed8, .gray8, .mono1 => null,
        _ => null,
    };
}

/// A pen from a value in a surface's format: packPen backwards.
///
/// INPUTS:
/// - `format` - the surface's format.
/// - `value` - the bytes of one pixel, right-aligned in the word.
///
/// RESULT:
/// 0xAARRGGBB. A format with fewer bits a channel gives the bits back
/// spread over the range rather than shifted up, so that all-ones comes
/// back as 0xFF and a value read out and written back is unchanged.
/// Opaque for a format that carries no alpha, since what is in a surface
/// is what is on the glass.
///
/// CONTEXT:
/// Any. It is arithmetic on its arguments.
pub fn unpackPen(format: PixelFormat, value: u32) Pen {
    return switch (format) {
        .bgra32 => value,
        .rgba32 => (value >> 24 & 0xFF) << 24 | (value & 0xFF) << 16 |
            (value >> 8 & 0xFF) << 8 | (value >> 16 & 0xFF),
        .bgr24 => 0xFF00_0000 | (value & 0x00FF_FFFF),
        .rgb24 => 0xFF00_0000 | (value & 0xFF) << 16 |
            (value >> 8 & 0xFF) << 8 | (value >> 16 & 0xFF),
        .rgb565 => blk: {
            const r: u32 = value >> 11 & 0x1F;
            const g: u32 = value >> 5 & 0x3F;
            const b: u32 = value & 0x1F;
            break :blk 0xFF00_0000 | (r << 3 | r >> 2) << 16 |
                (g << 2 | g >> 4) << 8 | (b << 3 | b >> 2);
        },
        .argb1555 => blk: {
            const r: u32 = value >> 10 & 0x1F;
            const g: u32 = value >> 5 & 0x1F;
            const b: u32 = value & 0x1F;
            const a: u32 = if (value >> 15 & 1 != 0) 0xFF else 0;
            break :blk a << 24 | (r << 3 | r >> 2) << 16 |
                (g << 3 | g >> 2) << 8 | (b << 3 | b >> 2);
        },
        // No RastPort can exist on one of these: CreateRastPortTagList
        // refuses a format it cannot pack a pen for, so nothing can read
        // a pixel out of one either.
        else => 0xFF00_0000,
    };
}

/// The View: the board this library draws on when nobody names a buffer.
///
/// INPUTS:
/// - `gb` - the library's base, which is left holding the answer.
///
/// RESULT:
/// The first board rtg.library lists, or null on a machine that has no
/// display - which is not an error, and a caller that named its own buffer
/// never asks.
///
/// BEHAVIOR:
/// It asks rtg afresh every time and leaves the answer in the base, rather
/// than keeping the first board it ever saw. A board can be deleted, and a
/// pointer kept across that is a pointer into freed memory - so the base
/// holds the View as last resolved, not a claim on one. It costs a single
/// read of a list head.
///
/// It also means a display made after this library's init is found.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here, around the read of rtg's board list, as exec's
///   contract for walking a list asks. The board outlives the Forbid, but
///   only until someone deletes it, which is why it is asked for again
///   each time rather than trusted.
/// - Process: a Task will do.
pub fn view(gb: *GraphicsBase) ?*RtgBoard {
    gb.sys_base.Forbid();
    defer gb.sys_base.Permit();
    gb.view = gb.rtg_base.NextBoard(null);
    return gb.view;
}

/// The buffer a new RastPort draws into, from its tags.
///
/// INPUTS:
/// - `gb` - the library's base.
/// - `tag_list` - the caller's tags, or null.
///
/// RESULT:
/// The surface, and the `RtgBitMap` behind it when there is one. Null when
/// a board was named that shows nothing, or when nothing was named and
/// there is no display.
///
/// BEHAVIOR:
/// `RPTAG_Surface` wins if it is there, then `RPTAG_BitMap`, then
/// `RPTAG_Board`, then the View. A surface named on its own has no board,
/// so it is drawn in software; the other three all end at a board's
/// buffer.
pub fn surfaceFor(gb: *GraphicsBase, tag_list: ?[*]const TagItem) ?struct { *Surface, ?*RtgBitMap } {
    const ub = gb.utility_base;

    const named_surface = ub.GetTagData(graphics.RPTAG_Surface, 0, tag_list);
    if (named_surface != 0) return .{ @ptrFromInt(named_surface), null };

    const named_bitmap = ub.GetTagData(graphics.RPTAG_BitMap, 0, tag_list);
    if (named_bitmap != 0) {
        const bm: *RtgBitMap = @ptrFromInt(named_bitmap);
        return .{ @ptrCast(bm), bm };
    }

    const named_board = ub.GetTagData(graphics.RPTAG_Board, 0, tag_list);
    const board: *RtgBoard = if (named_board != 0)
        @ptrFromInt(named_board)
    else
        view(gb) orelse return null;

    const bm = gb.rtg_base.BoardDisplayBitMap(board) orelse return null;
    return .{ @ptrCast(bm), bm };
}

/// The whole of the RastPort's surface, as a rectangle.
///
/// The whole of a RastPort's surface, which is what its clip is clamped
/// against and what covers everything when filled.
///
/// INPUTS:
/// - `rp` - the RastPort.
pub fn boundsOf(rp: *const RastPort) graphics.Rect {
    return .{
        .min_x = 0,
        .min_y = 0,
        .max_x = @intCast(rp.surface.width),
        .max_y = @intCast(rp.surface.height),
    };
}

/// Sets one of the pens, with its copy in the surface's format.
///
/// Set one pen and keep its packed copy in step.
///
/// A pen that cannot be packed for this surface is refused rather than
/// half-applied: the surface's format was checked when the RastPort was
/// made, so this can only fail if the surface itself changed underneath,
/// and leaving the two copies disagreeing would draw the old colour for
/// ever after.
///
/// INPUTS:
/// - `rp` - the RastPort.
/// - `which` - the pen to set.
/// - `packed_copy` - its copy in the surface's format.
/// - `value` - the new colour, 0xAARRGGBB.
pub fn setPen(rp: *RastPort, which: *Pen, packed_copy: *u32, value: Pen) void {
    const bits = packPen(rp.surface.format, value) orelse {
        // It would have been applied half way, drawing the old colour for
        // ever after, so it is not applied at all and it says so.
        rp.last_error = graphics.GERR_BAD_FORMAT;
        return;
    };
    which.* = value;
    packed_copy.* = bits;
}
