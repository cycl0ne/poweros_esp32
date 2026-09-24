// SPDX-License-Identifier: MIT
//! imageclass: a rectangle that knows how to draw itself.
//!
//! An image is a box - where it is and how big - with two pens and, if it
//! has one, a shape one bit to a pixel. It is drawn by stencilling the
//! shape in the pens: a set bit takes the foreground pen, a clear one the
//! background pen, or nothing when the background pen is fully
//! transparent. That is what an icon, a pointer or an arrow on a button
//! is; an image that draws something else is a subclass that answers
//! `IM_DRAW` itself.
//!
//! The pens are graphics.library's: 0xAARRGGBB, never an index into a
//! palette, since this display has none.

const utility = @import("../utility/utility.zig");
const graphics = @import("../graphics/graphics.zig");
const classusr = @import("classusr.zig");
const MethodID = classusr.MethodID;

// --- attributes ---------------------------------------------------------------

pub const IA_Dummy = utility.TAG_USER + 0x20000;
/// The box's left edge and top edge, added to the offset it is drawn at.
pub const IA_Left = IA_Dummy + 0x01;
pub const IA_Top = IA_Dummy + 0x02;
/// Its size. 80 by 40 until told otherwise.
pub const IA_Width = IA_Dummy + 0x03;
pub const IA_Height = IA_Dummy + 0x04;
/// The pen a set bit of the shape is drawn in. Opaque black by default.
pub const IA_FGPen = IA_Dummy + 0x05;
/// The pen a clear bit is drawn in. Fully transparent by default, which
/// leaves those pixels alone.
pub const IA_BGPen = IA_Dummy + 0x06;
/// The shape: `height` rows of `(width + 7) / 8` bytes, the leftmost pixel
/// in the highest bit - what graphics.library's BltTemplate takes. Not
/// copied, so it must outlive the image. Null draws nothing.
pub const IA_Data = IA_Dummy + 0x07;

// Numbers the reference gives these, named so that they stay taken. No
// class here reads them yet; a class that does will say what it does.
pub const IA_LineWidth = IA_Dummy + 0x08;
pub const IA_ShadowPen = IA_Dummy + 0x09;
pub const IA_HighlightPen = IA_Dummy + 0x0A;
pub const IA_Pens = IA_Dummy + 0x0E;
pub const IA_Resolution = IA_Dummy + 0x0F;
pub const IA_Font = IA_Dummy + 0x13;
pub const IA_Outline = IA_Dummy + 0x14;
pub const IA_DoubleEmboss = IA_Dummy + 0x16;
/// Answered by an image that draws `IDS_DISABLED` itself, so that a gadget
/// shows it that way instead of ghosting it.
pub const IA_SupportsDisable = IA_Dummy + 0x1A;
pub const SYSIA_Size = IA_Dummy + 0x0B;
pub const SYSIA_Depth = IA_Dummy + 0x0C;
pub const SYSIA_ReferenceFont = IA_Dummy + 0x19;

// This library's own attributes start here, clear of every number the
// reference uses and of the ones it left for what came after it.
pub const IA_Own = IA_Dummy + 0x100;

// --- fillrectclass: a box filled with a pattern ------------------------------

/// The pattern: rows of 16 pixels, two bytes a row, the leftmost pixel in
/// the highest bit of the first byte, `1 << IA_APatSize` rows of them. It
/// is repeated over the box and anchored to the surface, so two boxes of
/// one pattern line up where they meet. Not copied. Null fills the box
/// solid in `IA_FGPen`.
pub const IA_APattern = IA_Dummy + 0x10;
/// How many rows the pattern has, as a power of two: 0 is one row, 1 two,
/// 2 four.
pub const IA_APatSize = IA_Dummy + 0x11;
/// The draw mode it is filled in, graphics.library's DRMD_: `DRMD_JAM1`,
/// the default, leaves a clear bit's pixel alone; `DRMD_JAM2` puts
/// `IA_BGPen` there; `DRMD_COMPLEMENT` inverts what a set bit covers.
pub const IA_Mode = IA_Dummy + 0x12;

// --- frameiclass: a bevelled frame -------------------------------------------

/// The next image in a chain: a `*Object` of an image class, drawn after
/// this one at its own place.
pub const IA_NextImage = IA_Own + 0x00;
/// Sunk into the surface rather than raised: the shine and shadow swap.
pub const IA_Recessed = IA_Dummy + 0x15;
/// The edges only, leaving the inside alone.
pub const IA_EdgesOnly = IA_Dummy + 0x17;
/// FRAME_DEFAULT, FRAME_BUTTON or FRAME_RIDGE.
pub const IA_FrameType = IA_Dummy + 0x1B;
/// One pixel of shine above and left, one of shadow below and right.
pub const FRAME_DEFAULT: u32 = 0;
/// The same with the sides two pixels thick: a button.
pub const FRAME_BUTTON: u32 = 1;
/// A raised frame with a sunk one just inside it: a ridge, or with
/// IA_Recessed a groove.
pub const FRAME_RIDGE: u32 = 2;
/// A ridge with a further frame inside it, for a box something is dropped
/// into.
pub const FRAME_ICONDROPBOX: u32 = 3;

// --- sysiclass: the system's own images ---------------------------------------

/// Which image: `DEPTHIMAGE`, `ZOOMIMAGE`, `SIZEIMAGE`, `CLOSEIMAGE`,
/// `MENUCHECK` or `AMIGAKEY`.
pub const SYSIA_Which = IA_Dummy + 0x0D;
/// The screen's DrawInfo, whose pens it is drawn in. Without one it uses
/// the default pens.
pub const SYSIA_DrawInfo = IA_Dummy + 0x18;
/// Two windows, one over the other: the depth gadget.
pub const DEPTHIMAGE: u32 = 0x00;
/// A box in a box: the zoom gadget.
pub const ZOOMIMAGE: u32 = 0x01;
/// A corner: the size gadget.
pub const SIZEIMAGE: u32 = 0x02;
/// A dot in a box: the close gadget.
pub const CLOSEIMAGE: u32 = 0x03;
/// A tick: what a checked menu item shows at its left. Sized to the
/// DrawInfo's font unless IA_Width and IA_Height say otherwise.
pub const MENUCHECK: u32 = 0x10;
/// The Amiga key: what a menu item with a shortcut shows before its
/// character. Sized as MENUCHECK is, twice as wide.
pub const AMIGAKEY: u32 = 0x11;

// --- methods ------------------------------------------------------------------

/// Draw in a state (`IDS_`). `ImpDraw`.
pub const IM_DRAW: MethodID = 0x202;
/// Whether a point is inside. `ImpHitTest`; the answer is 1 or 0.
pub const IM_HITTEST: MethodID = 0x203;
/// Clear the box in the RastPort's background pen. `ImpErase`.
pub const IM_ERASE: MethodID = 0x204;
/// Draw at a new place and clear the old one. Not handled by any class
/// yet.
pub const IM_MOVE: MethodID = 0x205;
/// Draw fitted to the dimensions in the message. imageclass has one size,
/// so it draws as `IM_DRAW` - sent to the object's own class, so a
/// subclass that draws itself is the one that answers. `ImpDraw`.
pub const IM_DRAWFRAME: MethodID = 0x206;
/// The frame that would go round a box. Not handled by imageclass.
pub const IM_FRAMEBOX: MethodID = 0x207;
/// IM_HITTEST with the dimensions in the message in place of the image's.
pub const IM_HITFRAME: MethodID = 0x208;
/// IM_ERASE with the dimensions in the message in place of the image's.
pub const IM_ERASEFRAME: MethodID = 0x209;

// --- states for IM_DRAW -------------------------------------------------------

pub const IDS_NORMAL: u32 = 0;
pub const IDS_SELECTED: u32 = 1;
pub const IDS_DISABLED: u32 = 2;
pub const IDS_BUSY: u32 = 3;
pub const IDS_INDETERMINATE: u32 = 4;
pub const IDS_INACTIVENORMAL: u32 = 5;
pub const IDS_INACTIVESELECTED: u32 = 6;
pub const IDS_INACTIVEDISABLED: u32 = 7;
pub const IDS_SELECTEDDISABLED: u32 = 8;

/// A screen's pens and font, for images that draw in them
/// (`screens.zig`).
pub const DrawInfo = @import("screens.zig").DrawInfo;

/// A width and a height.
pub const Dimensions = extern struct {
    width: i32 = 0,
    height: i32 = 0,
};

/// imageclass's instance data: what an image is.
pub const Image = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    fg_pen: graphics.Pen = 0,
    bg_pen: graphics.Pen = 0,
    data: ?[*]const u8 = null,
    /// The next image to draw with this one, at its own place. `DrawImage`
    /// and `EraseImage` follow the chain, so a picture made of several
    /// pieces is one image to whoever draws it. A hit test asks only the
    /// first - what a point is in is one thing, not a list.
    next: ?*@import("classes.zig").Object = null,
};

/// IM_DRAW and IM_DRAWFRAME.
pub const ImpDraw = extern struct {
    method_id: MethodID,
    /// Where to draw. Its pens and draw mode are as they were afterwards.
    rast_port: *graphics.RastPort,
    /// Added to the image's own left and top.
    offset: graphics.Point = .{},
    /// IDS_. imageclass draws every state the same.
    state: u32 = IDS_NORMAL,
    /// May be null.
    draw_info: ?*DrawInfo = null,
    /// For IM_DRAWFRAME only.
    dimensions: Dimensions = .{},
};

/// IM_FRAMEBOX: how big a frame has to be to sit comfortably around
/// something, and where it then goes.
///
/// The frame answers with a box that holds `contents` with room to spare,
/// centred on it - so a button asks its frame how much bigger than its
/// label it must be. `FRAMEF_SPECIFY` means the caller has already decided
/// the size and wants only the placing worked out.
pub const ImpFrameBox = extern struct {
    method_id: MethodID = IM_FRAMEBOX,
    /// What has to fit inside, in whatever coordinates the caller is using.
    contents: *const Box,
    /// Where the answer goes. With `FRAMEF_SPECIFY` its width and height
    /// come in as the size to use.
    frame: *Box,
    /// May be null.
    draw_info: ?*DrawInfo = null,
    flags: u32 = 0,
};

/// A box, as `IM_FRAMEBOX` speaks in.
pub const Box = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
};

/// The size in `ImpFrameBox.frame` is the caller's and is to be kept; only
/// where the frame goes is being asked.
pub const FRAMEF_SPECIFY: u32 = 1 << 0;

/// IM_ERASE and IM_ERASEFRAME.
pub const ImpErase = extern struct {
    method_id: MethodID,
    rast_port: *graphics.RastPort,
    offset: graphics.Point = .{},
    /// For IM_ERASEFRAME only.
    dimensions: Dimensions = .{},
};

/// IM_HITTEST and IM_HITFRAME.
pub const ImpHitTest = extern struct {
    method_id: MethodID,
    /// In the same coordinates as the image's left and top.
    point: graphics.Point,
    /// For IM_HITFRAME only.
    dimensions: Dimensions = .{},
};
