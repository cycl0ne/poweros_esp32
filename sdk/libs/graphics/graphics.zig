// SPDX-License-Identifier: MIT
//! graphics.library's types and constants.
//!
//! graphics.library is the layer that draws. What it draws into is
//! rtg.library's: a board's display memory, handed out as `RtgBitMap`s and
//! put on the glass with RefreshBitMap. rtg holds no drawing of its own -
//! a board offers what its engine can do and answers
//! RTGERR_NOT_SUPPORTED for the rest - and this is the layer that knows
//! how, in software, when the board does not.
//!
//! A caller never touches rtg.library to draw on the display. It opens
//! graphics.library and asks for a **RastPort**, which is a surface to
//! draw into and the state to draw with; with no tags it gets one on the
//! display. graphics.library opens rtg itself and finds the display on
//! first use.
//!
//! The RastPort is opaque. Its size and its fields are the library's, so
//! that it can grow for as long as the system does, and everything about
//! it is read and written through the `RPTAG_` tags - the same tags that
//! configure one at birth.
//!
//! Open it with OpenLibrary(GRAPHICSNAME, 0); its functions are in
//! sdk/interface/graphics.zig.

const TAG_USER = @import("../utility/tagitem.zig").TAG_USER;
const Surface = @import("../rtg/bitmaps.zig").Surface;
const RtgBitMap = @import("../rtg/bitmaps.zig").RtgBitMap;
const TagItem = @import("../utility/tagitem.zig").TagItem;
const GraphicsBase = @import("../../interface/graphics.zig").GraphicsBase;

/// The name to open it by.
pub const GRAPHICSNAME = "graphics.library";
/// The version a caller of this SDK asks for.
pub const GRAPHICS_VERSION = 0;
/// The name of the rtg board graphics.library's init brings the machine's
/// display up as, which is how anything finds that board again.
pub const DISPLAY_BOARD = "display";

/// A rectangle, half-open: `max_x` is one past the last pixel, so the
/// width is `max_x - min_x` and an empty rectangle is one whose max is not
/// past its min. Half-open because every operation done to a rectangle
/// here - intersect, subtract, clip, point-in - is arithmetic on its
/// edges, and edges that meet are the ones that make those come out right
/// with no `+ 1` anywhere. The `- 1` belongs inside a span loop and never
/// in a rectangle.
pub const Rect = extern struct {
    min_x: i32 = 0,
    min_y: i32 = 0,
    /// One past the last pixel.
    max_x: i32 = 0,
    /// One past the last row.
    max_y: i32 = 0,

    pub inline fn width(r: Rect) i32 {
        return r.max_x - r.min_x;
    }

    pub inline fn height(r: Rect) i32 {
        return r.max_y - r.min_y;
    }

    /// Nothing is inside it, so nothing is drawn for it.
    pub inline fn isEmpty(r: Rect) bool {
        return r.max_x <= r.min_x or r.max_y <= r.min_y;
    }

    /// What the two have in common, which may be empty.
    pub inline fn intersect(a: Rect, b: Rect) Rect {
        return .{
            .min_x = @max(a.min_x, b.min_x),
            .min_y = @max(a.min_y, b.min_y),
            .max_x = @min(a.max_x, b.max_x),
            .max_y = @min(a.max_y, b.max_y),
        };
    }

    /// The smallest rectangle holding both. An empty one is not a point at
    /// the origin, so it is left out rather than dragging the answer to
    /// (0,0).
    pub inline fn unionWith(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        return .{
            .min_x = @min(a.min_x, b.min_x),
            .min_y = @min(a.min_y, b.min_y),
            .max_x = @max(a.max_x, b.max_x),
            .max_y = @max(a.max_y, b.max_y),
        };
    }

    /// The same rectangle somewhere else.
    pub inline fn offset(r: Rect, dx: i32, dy: i32) Rect {
        return .{
            .min_x = r.min_x + dx,
            .min_y = r.min_y + dy,
            .max_x = r.max_x + dx,
            .max_y = r.max_y + dy,
        };
    }

    /// Whether the point is inside. Half-open, so the right and bottom
    /// edges are outside.
    pub inline fn contains(r: Rect, x: i32, y: i32) bool {
        return x >= r.min_x and y >= r.min_y and x < r.max_x and y < r.max_y;
    }
};

/// One place a drawing call may put pixels, and where those pixels go.
///
/// A RastPort that has a list of these draws each part of what it is asked
/// for into that part's own surface. With no list it has one target - its
/// own surface, at its own coordinates - which is what a plain RastPort on
/// a bitmap or on the display is.
///
/// This is the one structure graphics.library shares with whatever manages
/// windows: that code builds the list, this library walks it. It is not
/// opaque for the same reason `Surface` is not - a thing crossing between
/// two libraries has to be readable on both sides.
pub const ClipTarget = extern struct {
    /// What may be written, **in the RastPort's own coordinates**.
    rect: Rect = .{},
    /// Where those pixels actually go.
    surface: *Surface,
    /// The board's buffer, when that is what this is: the drawing engine
    /// and the hand-on after a write are its. Null for plain memory.
    bitmap: ?*RtgBitMap = null,
    /// Added to a coordinate in the RastPort's space to reach the surface.
    /// For a window drawn on the display this is where the window's
    /// top-left sits on it, which is what lets the window draw at (0,0)
    /// and mean its own corner.
    dx: i32 = 0,
    dy: i32 = 0,
    /// The next place, or null.
    ///
    /// **The list is in order of `min_y`, then `min_x`.** A blit that moves
    /// a rectangle over the surface it is already on walks away from where
    /// it is going, so that it reads before it writes; it can only get that
    /// right if the pieces arrive in the order the pixels lie in. Whatever
    /// builds the list keeps it so.
    next: ?*ClipTarget = null,
};

// --- what went wrong -------------------------------------------------------
//
// The error lives in the RastPort, read with RPTAG_LastError. A RastPort
// belongs to whoever is drawing with it, so two tasks drawing at once have
// two of them and neither can overwrite the other's answer - which is why
// there is no one-word "last error" for the whole library to race over.
//
// The two calls that make something have no RastPort to put it in, so they
// take a pointer to write it through instead: RPTAG_ErrorPtr and
// BMTAG_ErrorPtr.
//
// Every call sets it, and a call that worked sets GERR_OK - so what is read
// belongs to the call just made and never to one five calls ago. GetRPAttrs
// is the exception: it does not set it, or reading the error would clear it.

/// Nothing went wrong.
pub const GERR_OK: i32 = 0;
/// There was not enough memory.
pub const GERR_NO_MEMORY: i32 = -1;
/// Nothing named a buffer and this machine has no display to fall back on.
pub const GERR_NO_DISPLAY: i32 = -2;
/// The surface's format is one no pen can be packed for, or a blit was
/// asked to cross two formats, which is a conversion and not a blit.
pub const GERR_BAD_FORMAT: i32 = -3;
/// A width or a height was 0.
pub const GERR_BAD_SIZE: i32 = -4;
/// The RastPort has no font, so there was nothing to draw the text with.
/// `OpenFont` does not put a font on a RastPort - `RPTAG_Font` does - and
/// forgetting the second is the easiest mistake to make here.
pub const GERR_NO_FONT: i32 = -5;
/// The furthest code there is, for a caller checking a range.
pub const GERR_LAST: i32 = GERR_NO_FONT;

/// A font: the glyphs and what a caller needs to lay them out.
///
/// Opaque, as a RastPort is. What a caller wants to know about one - how
/// tall it is and where its baseline sits - is read from the RastPort it
/// is set on, with `RPTAG_FontHeight` and the rest, so there is one way
/// into a RastPort and not two.
pub const TextFont = opaque {};

/// What a font is, for a caller that wants to know rather than to draw.
/// `AddFont` takes one of these; `FontExtent` fills one in.
pub const FontExtent = extern struct {
    /// How far one character moves the point, and how tall the font is.
    width: i32 = 0,
    height: i32 = 0,
    /// How far down the height the baseline sits.
    baseline: i32 = 0,
    /// The styles the font was drawn with, which cannot be applied again.
    style: FontStyle = FS_NORMAL,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// Where one character's ink lands relative to the point, half-open.
    extent: Rect = .{},
};

/// How much room some text takes.
///
/// `width` is how far the point moves - what `TextLength` answers - and
/// `extent` is where the ink lands relative to the current point, so it is
/// above the line by the baseline and below it by the rest. Half-open like
/// every rectangle here, so `max_y - min_y` is the height and no `+ 1`
/// appears anywhere.
pub const TextExtent = extern struct {
    width: i32 = 0,
    height: i32 = 0,
    extent: Rect = .{},
};

/// Which way `TextFit` walks a string.
pub const TEXT_FORWARD: i32 = 1;
/// Backward, with `string` pointing at the **last** character rather than
/// the first - which is how a line is trimmed from its end.
pub const TEXT_BACKWARD: i32 = -1;

/// The name the fonts in this ROM go by: the system's own font, drawn
/// for it. Both are this name and differ by height: 8 and 16.
pub const POSPAZNAME = "pospaz.font";

/// How letters are drawn, on top of the font's own shape. The old names,
/// and the same bits.
pub const FontStyle = u8;
/// As the font was drawn.
pub const FS_NORMAL: FontStyle = 0;
/// Thickened by drawing each glyph over itself, moved one to the right.
pub const FSF_BOLD: FontStyle = 1;
/// Leant over, by moving each row right as it goes up.
pub const FSF_ITALIC: FontStyle = 2;
/// A line under the whole run.
pub const FSF_UNDERLINED: FontStyle = 4;
/// Wider than it was drawn. A font drawn this way has it in its style,
/// and is not widened again.
pub const FSF_EXTENDED: FontStyle = 8;

/// A place on a surface. The line and text calls draw from one.
pub const Point = extern struct {
    x: i32 = 0,
    y: i32 = 0,
};

/// An area of any shape, held as rectangles that do not overlap.
///
/// It is opaque, as a RastPort is: how the rectangles are kept is the
/// library's, so it can change. What a caller does with one is build it up
/// out of rectangles and other regions, ask whether a point is inside, and
/// give it to a RastPort as its clip.
pub const Region = opaque {};

/// A surface to draw into, and the state to draw it with: the pens, the
/// draw mode, the current point, and in time the clipping and the font.
///
/// It is opaque on purpose. A public structure's fields can never be
/// withdrawn or widened: once a field outgrows its type (a byte-wide pen,
/// say), the new state has to be reached around it with calls of its own,
/// beside a structure that still cannot change. Starting opaque costs a jump-table call per attribute and keeps the layout the
/// library's for good.
pub const RastPort = opaque {};

// --- the attribute tags ---------------------------------------------------
//
// One vocabulary: these configure a RastPort at birth in
// CreateRastPortTagList, and change it afterwards through SetRPAttrs. On a
// get, ti_Data is a pointer to where the value goes.
//
// The block is TAG_USER + 5000. Below TAG_USER there is nothing but the
// four words that drive a tag list (TAG_DONE, TAG_IGNORE, TAG_MORE,
// TAG_SKIP), so every library's tags live above it; rtg holds 4000, and
// 4100 upward in blocks of 64 for its drivers.

/// The block this library's tags start at.
pub const RPTAG_Dummy = TAG_USER + 5000;

/// `*RtgBitMap`: draw into this buffer of a board's. The board's engine is
/// then available, and what is drawn is handed on with RefreshBitMap.
pub const RPTAG_BitMap = RPTAG_Dummy + 1;
/// `*Surface`: draw into plain memory. There is no board behind it, so
/// every operation is done in software and nothing is refreshed.
pub const RPTAG_Surface = RPTAG_Dummy + 2;
/// `*RtgBoard`: draw into the buffer that board is displaying, instead of
/// the first board the library finds.
pub const RPTAG_Board = RPTAG_Dummy + 3;
/// u32, 0xAARRGGBB: the pen drawn with.
pub const RPTAG_APen = RPTAG_Dummy + 4;
/// u32, 0xAARRGGBB: the pen behind what is drawn.
pub const RPTAG_BPen = RPTAG_Dummy + 5;
/// `DrawMode`: how a pen meets what is already there.
pub const RPTAG_DrMd = RPTAG_Dummy + 6;
/// `*const Rect` to set, `*Rect` to get: what may be written, in the
/// surface's coordinates. It is clamped to the surface, so a clip cannot
/// open one up. Absent: all of the surface.
pub const RPTAG_ClipRect = RPTAG_Dummy + 7;

// --- these can be read but not set: they are the surface's, not the
// RastPort's, and a RastPort draws into the buffer it was made on.

/// `*Rect`: the whole of the surface, 0,0 to its width and height. What to
/// fill to cover everything, and the only way to find out how big a
/// display is.
pub const RPTAG_Bounds = RPTAG_Dummy + 8;
/// `*u32`: the surface's `PixelFormat`.
pub const RPTAG_Format = RPTAG_Dummy + 9;

/// `*const Point` to set, `*Point` to get: the current point, which Draw
/// draws from and Move moves. Setting it is what `Move` does; this is how
/// it is read back.
pub const RPTAG_Cursor = RPTAG_Dummy + 10;

/// u16 to set, `*u32` to get: which pixels along a line are drawn, as
/// sixteen bits used in turn and then begun again. `LINE_SOLID` is all of
/// them; 0xAAAA is every other one. Setting it starts the pattern at its
/// first bit, so two lines drawn with the same pattern begin the same way.
pub const RPTAG_LinePattern = RPTAG_Dummy + 14;

/// `?*Region` to set, `*usize` to get: what may be written, of any shape.
/// It narrows the clip rectangle rather than replacing it, so a drawing
/// call is clipped to both. Null takes it away again.
pub const RPTAG_ClipRegion = RPTAG_Dummy + 13;

/// `?*TextFont` to set, `*usize` to get: the font `Text` draws with. Null
/// takes it away, and `Text` then draws nothing.
pub const RPTAG_Font = RPTAG_Dummy + 15;
/// `FontStyle` to set, `*u32` to get: how letters are drawn on top of the
/// font's own shape.
pub const RPTAG_TextStyle = RPTAG_Dummy + 16;
/// `*u32`, get only: how tall the font is, in rows. 0 with no font.
pub const RPTAG_FontHeight = RPTAG_Dummy + 17;
/// `*u32`, get only: how far down the font's height its baseline sits, so
/// that a caller can line two fonts up.
pub const RPTAG_FontBaseline = RPTAG_Dummy + 18;
/// `*u32`, get only: how far `Text` moves along for one character.
pub const RPTAG_FontWidth = RPTAG_Dummy + 19;

/// The list of places this RastPort draws into (`?*ClipTarget`), or 0 for
/// none. With a list, the clip region is not consulted: whatever built the
/// list has already taken the caller's own clip into account, because only
/// it knows which pieces went where.
pub const RPTAG_ClipTargets = RPTAG_Dummy + 20;

/// How an area of this RastPort with nothing in it yet is painted: `0` for
/// its own background pen, `BACKFILL_NONE` for nothing at all, or a
/// `*utility.Hook` that paints it.
///
/// Whatever manages windows sets this, because it is what knows how a
/// window's ground is meant to look. This library only calls it: `EraseRect`
/// is the one call that consults it, and it says nothing about what a window
/// or a layer is.
pub const RPTAG_BackFill = RPTAG_Dummy + 21;

/// `RPTAG_BackFill` with this instead of a hook: leave the area exactly as
/// it is. A value and not a hook, so that "do nothing" costs no call.
pub const BACKFILL_NONE: usize = 1;

/// What a hook that paints an empty area is told.
///
/// The hook draws **through the RastPort it is handed**, with the ordinary
/// drawing calls, so what it puts down is clipped the way anything else
/// drawn through that RastPort is. It does not have to know what it can be
/// seen through, or whether it can be seen at all.
pub const BackFillMsg = extern struct {
    /// Whichever layer this RastPort belongs to, for a hook that was
    /// installed by something that knows - null when nothing does. This
    /// library never looks at it and never fills it in.
    layer: ?*anyopaque = null,
    /// What to paint, in the RastPort's own coordinates.
    area: Rect,
};

/// `*i32`, get only: what the last call on this RastPort went wrong with,
/// or `GERR_OK`. Reading it does not clear it - `GetRPAttrs` is the one
/// call that leaves it alone, since it is the call that reads it.
pub const RPTAG_LastError = RPTAG_Dummy + 11;
/// `*i32`, `CreateRastPortTagList` only: where to write what went wrong,
/// since a call that is making a RastPort has none to put it in yet.
pub const RPTAG_ErrorPtr = RPTAG_Dummy + 12;

// --- making a bitmap of one's own ------------------------------------------
//
// A block of its own, TAG_USER + 5100, so that a bitmap's tags and a
// RastPort's cannot be mistaken for one another.

/// The block the bitmap tags start at.
pub const BMTAG_Dummy = TAG_USER + 5100;

/// u32: how wide, in pixels. Required.
pub const BMTAG_Width = BMTAG_Dummy + 1;
/// u32: how tall, in pixels. Required.
pub const BMTAG_Height = BMTAG_Dummy + 2;
/// u32, a `PixelFormat`: what a pixel looks like. Absent: the friend's if
/// there is one, else the display's, else rgb565.
pub const BMTAG_Format = BMTAG_Dummy + 3;
/// `*RastPort`: make it so that it can be moved to and from that one
/// without converting anything - which today means in its format. Naming a
/// friend is how a caller says what the bitmap is for without having to
/// know what the display is.
pub const BMTAG_Friend = BMTAG_Dummy + 4;
/// bool: fill it with zeroes. Absent: its contents are whatever the memory
/// held.
pub const BMTAG_Clear = BMTAG_Dummy + 5;
/// `*i32`: where to write what went wrong, since this call has no RastPort
/// to put it in.
pub const BMTAG_ErrorPtr = BMTAG_Dummy + 6;

/// How a pen meets what is already in the surface. A set of flags rather
/// than a choice, since they combine: `DRMD_JAM2 | DRMD_INVERSVID` is a
/// real thing to want and so is `DRMD_JAM1 | DRMD_BLEND`.
pub const DrawMode = u8;

/// One colour: the pen goes down where the pattern says to draw, and
/// nothing happens where it does not. The default.
pub const DRMD_JAM1: DrawMode = 0;
/// Two colours: the foreground pen where the pattern says to draw, the
/// background pen everywhere else - so a dotted line lays down both
/// colours and covers what it crosses.
pub const DRMD_JAM2: DrawMode = 1;
/// What is already there is inverted instead of replaced. Drawing the same
/// thing twice puts the surface back as it was, which is how a rubber-band
/// outline is dragged about without keeping a copy of what is under it.
pub const DRMD_COMPLEMENT: DrawMode = 2;
/// The two pens change places. Written down as its own flag rather than
/// left to the caller to do because it is what a highlighted piece of text
/// wants, and text will want it a glyph at a time.
pub const DRMD_INVERSVID: DrawMode = 4;
/// Compose by the pen's alpha rather than writing it. Without it a pen is
/// written whatever its alpha, which is what a caller wants when the
/// surface itself carries one.
pub const DRMD_BLEND: DrawMode = 8;

/// A solid line: every pixel of it is drawn.
pub const LINE_SOLID: u16 = 0xFFFF;

/// A pen is 0x00RRGGBB to 0xFFRRGGBB: a colour and its coverage, never an
/// index into anything. This panel has no palette, and a colour already
/// packed into one surface's format would be the wrong bits for the next.
/// The library packs a pen once, when it is set.
pub const Pen = u32;

/// A pen that covers what is under it. Only an opaque pen can be handed to
/// a board's engine, which takes one colour word and writes it; anything
/// less has to be composed pixel by pixel, in software.
pub inline fn penIsOpaque(value: Pen) bool {
    return value >> 24 == 0xFF;
}

/// 0xAARRGGBB from its parts.
pub inline fn penARGB(alpha: u8, red: u8, green: u8, blue: u8) Pen {
    return @as(Pen, alpha) << 24 | @as(Pen, red) << 16 |
        @as(Pen, green) << 8 | @as(Pen, blue);
}

/// 0xFFRRGGBB from its parts: a pen that hides what is under it.
pub inline fn penRGB(red: u8, green: u8, blue: u8) Pen {
    return penARGB(0xFF, red, green, blue);
}

/// Put a font on a RastPort, which is what `OpenFont` does not do.
///
/// `OpenFont` takes a name and a height and has no RastPort to put the
/// answer on - a font is shared, and three RastPorts can draw with one at
/// the same time. So opening a font and drawing with it are two steps, and
/// this is the second one written out:
///
///     const font = gb.OpenFont(graphics.POSPAZNAME, 8) orelse return;
///     graphics.SetFont(gb, rp, font);
///
/// It is inline and it is here rather than a slot of its own, because a
/// font is an attribute like the pens, the draw mode and the clip region,
/// and those are read and written through `SetRPAttrs`/`GetRPAttrs`. A
/// convenience slot for each attribute is the pile of accessors the tag
/// vocabulary exists to avoid, and an LVO can never be taken back; this
/// costs no slot, still goes through the jump table, and can be changed.
///
/// A RastPort with no font draws no text and says so, with `GERR_NO_FONT`.
pub inline fn SetFont(gb: *GraphicsBase, rp: *RastPort, font: *TextFont) void {
    const tags = [_]TagItem{
        .{ .tag = RPTAG_Font, .data = @intFromPtr(font) },
        .{},
    };
    gb.SetRPAttrs(rp, &tags);
}
