// SPDX-License-Identifier: MPL-2.0
//! A layer with a bitmap of its own, and the window it shows of it.
//!
//! `LAYERSUPER` is `LAYERSMART` with the keeping done differently. A smart
//! layer keeps each covered piece in a surface this library allocates; a
//! super layer has **one bitmap, the program's own**, which may be larger
//! than the layer, and what is on the display is a window on to it that
//! `ScrollLayer` moves.
//!
//! So a super layer draws in **its bitmap's coordinates**, not in the
//! layer's: `(0,0)` is the bitmap's corner, and the part of it at
//! `(scroll_x, scroll_y)` is what shows. Everything else about a layer -
//! the clip targets, the tiling, the locks - is unchanged, because the
//! offset a target carries was always "what to add to reach the surface"
//! and the scroll simply goes into it.
//!
//! The pixels live in two places and neither is the whole truth:
//!
//! - Where the layer can be **seen**, drawing goes straight to the display
//!   and the bitmap does not have those pixels.
//! - Where it is **covered**, or is off the shown window altogether,
//!   drawing goes to the bitmap.
//!
//! Which means the two have to be squared up whenever what is visible
//! changes: a piece that has just been covered is copied out of the
//! display into the bitmap, and a piece that has just been uncovered is
//! copied back. That is the whole of it, and it is why a super layer is
//! never owed a redraw.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;
const rtg = sdk.rtg;
const Rect = graphics.Rect;
const TagItem = sdk.utility.TagItem;

const info_mod = @import("../layerinfo/_layerinfo.zig");
const Layer = info_mod.Layer;
const LayersBase = @import("../layers.zig").LayersBase;

/// What to add to a coordinate the layer draws in to reach the display.
/// For an ordinary layer that is where it sits; for a super layer the
/// window it is showing moves it as well.
///
/// INPUTS:
/// - `layer` - the layer.
pub fn origin(layer: *const Layer) struct { i32, i32 } {
    return .{ layer.bounds.min_x - layer.scroll_x, layer.bounds.min_y - layer.scroll_y };
}

/// What the layer draws into, in its own drawing coordinates: its own
/// rectangle, or the whole of its bitmap when it has one.
///
/// INPUTS:
/// - `layer` - the layer.
pub fn extent(layer: *const Layer) Rect {
    if (layer.super) |bm| return .{ .max_x = @intCast(bm.width), .max_y = @intCast(bm.height) };
    return .{ .max_x = layer.bounds.width(), .max_y = layer.bounds.height() };
}

/// Copy between the display and the layer's own bitmap, over the pieces of
/// `where` - which is in the display's coordinates.
///
/// `out` true takes it from the display into the bitmap, which is what a
/// piece about to be covered needs; false puts it back.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - a super layer.
/// - `where` - the pieces, in the display's coordinates.
/// - `out` - the direction.
pub fn move(lb: *LayersBase, layer: *Layer, where: *graphics.Region, out: bool) void {
    const gb = lb.graphics_base;
    const info = layer.info;
    const bm = layer.super orelse return;
    const dest_rp = info.display_rp orelse return;
    const ox, const oy = origin(layer);

    const n = gb.RegionRectangles(where, null, 0);
    if (n == 0) return;
    const bytes = n * @sizeOf(Rect);
    const mem = lb.sys_base.AllocPooled(info.pool, bytes) orelse return;
    defer lb.sys_base.FreePooled(info.pool, mem, bytes);
    const rects: [*]Rect = @ptrCast(@alignCast(mem));
    _ = gb.RegionRectangles(where, rects, n);

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const r = rects[i];
        // The same pixels, named twice: where they are on the display and
        // where they are in the bitmap.
        const sx = r.min_x - ox;
        const sy = r.min_y - oy;
        if (sx < 0 or sy < 0) continue;
        if (out) {
            _ = gb.BltBitMap(info.surface, r.min_x, r.min_y, bm, sx, sy, r.width(), r.height());
        } else {
            gb.BltBitMapRastPort(bm, sx, sy, dest_rp, r.min_x, r.min_y, r.width(), r.height());
        }
    }
}

/// Square the bitmap and the display up for a tiling that has changed.
///
/// `seen` is what the layer can see now; `layer.visible` is still what it
/// could see before. What has just been covered goes into the bitmap, and
/// what has just been uncovered comes back out of it - so the layer is
/// never asked to draw any of it again.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - a super layer.
/// - `seen` - what it can see now.
pub fn resquare(lb: *LayersBase, layer: *Layer, seen: *graphics.Region) bool {
    return saveCovered(lb, layer, seen) and bringBack(lb, layer, seen);
}

/// The first half: covered now, visible before - the display still has
/// those pixels and is about to lose them, so they go into the bitmap.
/// Nothing is drawn on the display.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - a super layer.
/// - `seen` - what it can see now.
pub fn saveCovered(lb: *LayersBase, layer: *Layer, seen: *graphics.Region) bool {
    const gb = lb.graphics_base;
    const going = info_mod.copyRegion(gb, layer.visible) orelse return false;
    defer gb.DisposeRegion(going);
    if (!gb.SubRegionRegion(seen, going)) return false;
    move(lb, layer, going, true);
    return true;
}

/// The second half: visible now, covered before - the bitmap has them and
/// the display does not.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - a super layer.
/// - `seen` - what it can see now.
pub fn bringBack(lb: *LayersBase, layer: *Layer, seen: *graphics.Region) bool {
    const gb = lb.graphics_base;
    const coming = info_mod.copyRegion(gb, seen) orelse return false;
    defer gb.DisposeRegion(coming);
    if (!gb.SubRegionRegion(layer.visible, coming)) return false;
    move(lb, layer, coming, false);
    return true;
}
