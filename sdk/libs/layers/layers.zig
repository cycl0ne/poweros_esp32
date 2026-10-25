// SPDX-License-Identifier: MIT
//! layers.library's types and constants: windows that share one buffer.
//!
//! A **layer** is a rectangle of a display that something draws into
//! without having to know what is in front of it. Every layer of one
//! `LayerInfo` shares the display's buffer - they are not composed out of
//! buffers of their own - so what makes a layer a layer is where it may
//! write, which is its own rectangle less whatever is in front.
//!
//! That is the whole of this library: it works out, for each layer, which
//! pieces of it are visible and where those pieces land, and hands the
//! answer to graphics.library as a `ClipTarget` list on the layer's
//! RastPort. graphics.library never learns what a window is, and this
//! library draws nothing.
//!
//! **A composed LayerInfo** (`LATAG_Compose`, on the 64-bit machines) is
//! the other way round: each layer draws into a buffer of its own, all of
//! it, covered or not, and what of it can be seen is copied on to the
//! display - when it is drawn, and when layers move. Nothing covered is
//! lost, so nothing is owed for being uncovered, and a move copies the
//! layer's pixels rather than asking for them again. A composed layer can
//! also show a picture of the caller's over part of itself, copied from
//! where it is rather than into the layer first (`ShowLayerPicture`).
//!
//! **A composed layer can have round corners, cast a shadow and be seen
//! through** (`LATAG_Corners`, `LATAG_Shadow`, `LATAG_Opacity`), set as it
//! is made or later (`SetLayerAttrsTagList`). None of it costs the
//! layer's program anything: the corners are where the layer is not, the
//! shadow is what is behind darkened as it is copied, and a layer seen
//! through is laid over what is behind it rather than copied. A layer
//! that is not composed has none of them.
//!
//! **A layer draws in its own coordinates.** `(0,0)` is the layer's
//! top-left wherever the layer happens to be, because the offset on to the
//! display rides in the clip targets rather than in anything the caller
//! has to add.
//!
//! Open it with OpenLibrary(LAYERSNAME, 0); its functions are in
//! sdk/interface/layers.zig.

const std = @import("std");
const TAG_USER = @import("../utility/tagitem.zig").TAG_USER;
const graphics = @import("../graphics/graphics.zig");
const Rect = @import("../graphics/graphics.zig").Rect;
const Point = @import("../graphics/graphics.zig").Point;

/// The name to open it by.
pub const LAYERSNAME = "layers.library";
/// The version a caller of this SDK asks for.
pub const LAYERS_VERSION = 0;

/// Every layer of one display, front to back. Opaque: which layer is where
/// and what each of them can see is this library's to keep.
pub const LayerInfo = opaque {};

/// One window's worth of a display. Opaque: a layer is reached through
/// `GetLayerAttrs` and the calls that move it, so what it holds can grow.
pub const Layer = opaque {};

// --- how a layer is refreshed ---------------------------------------------

/// What is covered is lost, and comes back as damage when it is uncovered
/// again. The cheapest layer there is: it costs no memory beyond its own
/// clipping, and the program has to be able to draw itself again.
pub const LAYERSIMPLE: u32 = 1;
/// What is covered is kept somewhere else and put back when it is
/// uncovered, so the program is never asked to redraw. It costs memory for
/// the covered parts.
pub const LAYERSMART: u32 = 2;
/// The layer has a bitmap of its own, larger than what is shown, and what
/// is on the display is a window on to it.
pub const LAYERSUPER: u32 = 4;

/// Set while `BeginUpdate` has narrowed the layer to its damage.
pub const LAYERUPDATING: u32 = 0x10;
/// The layer stays behind every ordinary one, whatever is created after
/// it: what a desktop is.
pub const LAYERBACKDROP: u32 = 0x40;
/// Something was uncovered that this layer has to draw again. The damage
/// says what.
pub const LAYERREFRESH: u32 = 0x80;

// --- making one ------------------------------------------------------------

/// The `LATAG_` block. rtg holds 4000 and the 64-blocks from 4100;
/// graphics holds 5000 and 5100; this is the next one clear.
pub const LATAG_Dummy = TAG_USER + 5200;

/// Where the layer goes, as a `*const Rect` in the display's coordinates.
/// Required: a layer with no rectangle is nothing.
pub const LATAG_Bounds = LATAG_Dummy + 1;
/// How it is refreshed: `LAYERSIMPLE`, `LAYERSMART` or `LAYERSUPER`.
/// `LAYERSIMPLE` if it is not said.
pub const LATAG_Refresh = LATAG_Dummy + 2;
/// True to put the new layer behind every other one instead of in front.
pub const LATAG_Behind = LATAG_Dummy + 3;
/// True to make it a backdrop layer (`LAYERBACKDROP`).
pub const LATAG_Backdrop = LATAG_Dummy + 4;
/// A `*Hook` to paint an area of the layer that has become part of it and
/// has nothing in it yet - a new layer, or the part a resize added. It is
/// called with the layer's RastPort as the object and a `BackFillMsg` as
/// the message, once per rectangle, in the layer's own coordinates.
///
/// Not given, the area is filled with the RastPort's background pen.
/// `LAYERS_NOBACKFILL` leaves it exactly as it was, which is what a layer
/// that is about to draw all of itself anyway wants.
pub const LATAG_BackFill = LATAG_Dummy + 6;

/// The bitmap a `LAYERSUPER` layer draws into, as a `*Surface` from
/// `AllocBitMapTagList`. It may be bigger than the layer, and what is on
/// the display is a window on to it that `ScrollLayer` moves. Required for
/// `LAYERSUPER` and ignored otherwise; it stays the caller's to free, and
/// must outlive the layer.
pub const LATAG_SuperBitMap = LATAG_Dummy + 7;

/// A `*Layer` of the same display this one moves and sizes with: moving or
/// sizing that layer moves and sizes this one by the same amounts, in the
/// same pass, so neither is uncovered by the other on the way and neither
/// owes a redraw for it - a window's interior with its border. Moved on
/// its own, this layer moves alone. One step only: a layer moving with
/// this one does not move when this one's own layer does. Deleting that
/// layer leaves this one on its own.
pub const LATAG_MovesWith = LATAG_Dummy + 8;

/// For `NewLayerInfoTagList`: true to compose its layers, each in a buffer
/// of its own (see the top of this file). Only a display that is a
/// board's buffer can be composed, and only on the 64-bit machines; asked
/// for anywhere else, the LayerInfo is made as without it.
pub const LATAG_Compose = LATAG_Dummy + 9;
/// The radius of a composed layer's corners, in pixels (0, square): its
/// four corners are cut round. What is behind shows there, a point there
/// is not the layer's (`WhichLayer`), and what is drawn there goes into
/// the layer's buffer and is never shown. `cornerCut` says which pixels
/// go, for whoever draws an outline along them.
pub const LATAG_Corners = LATAG_Dummy + 10;
/// The size of the shadow a composed layer casts on what is behind it, in
/// pixels (0, none): soft, from as far out as the size all round, and a
/// third of it lower than the layer. What is behind is darkened as it is
/// copied on to the display; nothing is drawn, and the layer's program
/// sees none of it. Up to 32.
pub const LATAG_Shadow = LATAG_Dummy + 11;
/// How much a composed layer covers what is behind it: 255, all of it
/// (the default), down to 0, none - it is not seen. Below 255 the layer
/// and its shadow are laid over what is behind them, and **what is drawn
/// in it, or behind it, shows when they are next shown**: when the
/// opacity is set again, or the layer moved. It is for a layer coming or
/// going, set at every step of the way, not for one that stays so.
pub const LATAG_Opacity = LATAG_Dummy + 12;
/// True: the layer is seen and does not count: a point on it is the
/// layer's behind (`WhichLayer`), and the layer behind it has none in
/// front of it there (`LATAG_GetInFront`). What a window that has gone
/// leaves while it fades. False, the default, makes it count again.
pub const LATAG_Ghost = LATAG_Dummy + 13;
/// Where to write the error if the call fails, as an `*i32`. The layer
/// that would have carried it does not exist yet, which is why this is
/// here at all.
pub const LATAG_ErrorPtr = LATAG_Dummy + 5;

/// The radius the corners of a layer `width` by `height` are cut at when
/// `radius` is asked for (`LATAG_Corners`): no more than half the layer's
/// width or height.
pub fn cornerRadius(radius: u32, width: u32, height: u32) u32 {
    return @min(radius, @min(width, height) / 2);
}

/// How many pixels of one row of a corner of `radius` are cut away
/// (`LATAG_Corners`), counted from the layer's edge, row 0 being the
/// outermost: those whose middle is outside the circle. The same for all
/// four corners, mirrored; 0 for a row at or past the radius. The pixel
/// after them is the first of the layer, which is where an outline goes.
///
/// INPUTS:
/// - `radius` - the corners' radius, in pixels.
/// - `row` - the row, from the layer's top or bottom edge.
pub fn cornerCut(radius: u32, row: u32) u32 {
    if (row >= radius) return 0;
    // In halves of a pixel: the circle's middle is (r, r), a pixel's is
    // (x + 1/2, y + 1/2), and a pixel is kept when its middle is inside.
    const twice: u64 = 2 * @as(u64, radius);
    const down = twice - 2 * @as(u64, row) - 1;
    const across = std.math.sqrt(twice * twice - down * down);
    return if (across >= twice) 0 else @intCast((twice - across) / 2);
}

/// `LATAG_BackFill` with this instead of a hook: leave the area as it is.
/// It is a value and not a hook, so that "do nothing" costs no code and no
/// call.
pub const LAYERS_NOBACKFILL: usize = graphics.BACKFILL_NONE;

/// What a hook called over the pieces of a layer is told: which layer, and
/// which piece.
///
/// It is graphics.library's, because a RastPort carries the hook now and
/// `EraseRect` calls it - so an image erased inside a window is painted the
/// way the window paints its ground, without either of them having to know
/// what a layer is. `layer` is null unless whatever installed the hook knew
/// which layer it was for; this library fills it in, `DoHookClipRects` and
/// `EraseRect` do not.
pub const BackFillMsg = graphics.BackFillMsg;

// --- reading one back ------------------------------------------------------

/// `*Rect`: where the layer is, in the display's coordinates.
pub const LATAG_GetBounds = LATAG_Dummy + 16;
/// `*u32`: `LAYER*` flags as they are now.
pub const LATAG_GetFlags = LATAG_Dummy + 17;
/// `*usize`: the layer's RastPort, which is what draws into it.
pub const LATAG_GetRastPort = LATAG_Dummy + 18;
/// `*usize`: the damage region, or 0. It is in the **layer's** coordinates
/// and it is this library's, so it is read and not kept.
pub const LATAG_GetDamage = LATAG_Dummy + 19;
/// `*Point`: where in its own bitmap a `LAYERSUPER` layer is showing.
pub const LATAG_GetScroll = LATAG_Dummy + 21;
/// `*i32`: what went wrong in the last call on this layer.
pub const LATAG_GetLastError = LATAG_Dummy + 20;
/// `*usize`: the layer just in front of it, or 0 when it is the frontmost -
/// how a depth gadget decides between to the front and to the back.
pub const LATAG_GetInFront = LATAG_Dummy + 22;
/// `*u32`: 1 when `ShowLayerPicture` can show a picture in the layer - it
/// is composed, drawing into a buffer of its own, and not a super layer -
/// else 0.
pub const LATAG_GetComposed = LATAG_Dummy + 23;

// --- what went wrong -------------------------------------------------------

/// Nothing did.
pub const LERR_OK: i32 = 0;
/// There was not enough memory.
pub const LERR_NO_MEMORY: i32 = -1;
/// A layer was asked for with no bounds, or with an empty rectangle.
pub const LERR_BAD_BOUNDS: i32 = -2;
/// The RastPort for the layer could not be made, which on a machine with
/// no display is what happens.
pub const LERR_NO_RASTPORT: i32 = -3;
/// The call asked for something this library does not do: a layer made
/// to move with a layer of another display.
pub const LERR_NOT_DONE: i32 = -4;
/// A `LAYERSUPER` layer was asked for without a bitmap to draw into, or
/// with one smaller than the layer.
pub const LERR_NO_SUPERBITMAP: i32 = -5;
/// The furthest code there is, for a caller checking a range: every code
/// lies between it and `LERR_OK`.
pub const LERR_LAST: i32 = LERR_NO_SUPERBITMAP;
