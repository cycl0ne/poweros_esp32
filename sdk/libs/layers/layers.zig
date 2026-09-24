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
//! **A layer draws in its own coordinates.** `(0,0)` is the layer's
//! top-left wherever the layer happens to be, because the offset on to the
//! display rides in the clip targets rather than in anything the caller
//! has to add.
//!
//! Open it with OpenLibrary(LAYERSNAME, 0); its functions are in
//! sdk/interface/layers.zig.

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

/// Where to write the error if the call fails, as an `*i32`. The layer
/// that would have carried it does not exist yet, which is why this is
/// here at all.
pub const LATAG_ErrorPtr = LATAG_Dummy + 5;

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
/// The call asked for something this library does not do. Nothing
/// returns it at present; it stays so that a code once returned keeps its
/// meaning.
pub const LERR_NOT_DONE: i32 = -4;
/// A `LAYERSUPER` layer was asked for without a bitmap to draw into, or
/// with one smaller than the layer.
pub const LERR_NO_SUPERBITMAP: i32 = -5;
/// The furthest code there is, for a caller checking a range: every code
/// lies between it and `LERR_OK`.
pub const LERR_LAST: i32 = LERR_NO_SUPERBITMAP;
