// SPDX-License-Identifier: MPL-2.0
//! MoveSizeLayer: moves a layer and changes its size in one retile.
//!
//! Both are the same operation - a new rectangle - and both have the same
//! problem: the layer's pixels are on a display it shares, and after the
//! move they have to be wherever the layer now is. What cannot be brought
//! along is what the layer is owed, or what it gets back out of its own
//! keeping.
//!
//! The two refresh modes answer that differently, and each answer is the
//! cheap one for its mode:
//!
//! - **Simple.** The pixels that are visible before and still visible
//!   after are copied across the display, which is one blit per piece and
//!   no memory at all. Whatever could not be carried - a part that was
//!   covered, or that the new place has covered, or that the old rectangle
//!   did not contain - becomes damage, which is what a simple layer is
//!   for.
//! - **Smart.** The whole layer is put into its own keeping first, as
//!   though it had been covered completely, and the move then works from
//!   there: what ends up visible is copied back out, what ends up covered
//!   stays kept. It costs a copy of the layer both ways and it is never
//!   owed a redraw, which is what a smart layer is for.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;
const Rect = graphics.Rect;
const TagItem = sdk.utility.TagItem;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const tile = @import("../tile/_tile.zig");
const smart = @import("../smart/_smart.zig");
const backfill = @import("../backfill/_backfill.zig");
const super = @import("../super/_super.zig");
const _locks = @import("../locks/_locks.zig");
const LayersBase = @import("../layers.zig").LayersBase;

/// Moves a layer and changes its size together.
///
/// SYNOPSIS:
/// ```zig
/// fn MoveSizeLayer(lb: *LayersBase, layer: *Layer, dx: i32, dy: i32, dw: i32, dh: i32) bool
/// ```
///
/// SINCE: 0.1. LVO -100.
///
/// INPUTS:
/// - `layer` - the layer.
/// - `dx` - how far its top-left moves across, in the display's coordinates.
/// - `dy` - how far it moves down.
/// - `dw` - how much wider it gets; negative makes it narrower.
/// - `dh` - how much taller it gets; negative makes it shorter.
///
/// RESULT:
/// True, or false with the reason in the layer: `LERR_BAD_BOUNDS` if it
/// would be left with nothing in it, `LERR_NO_MEMORY` if the tiling could
/// not be worked out. All four 0 does nothing and answers true.
///
/// BEHAVIOR:
/// One retile and one pass over the pixels, where a move and then a resize
/// would be two of each and would put the layer somewhere it was never
/// asked to be in between. A layer draws at its own corner, so nothing it
/// has drawn moves in its own coordinates. A simple layer keeps the pixels
/// that are visible before and after - they are copied across the display -
/// and is owed the rest as damage; a smart layer is owed nothing. What a
/// growing layer gains has never held anything and is painted with its
/// backfill.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the display's layers.
/// - Interrupts: no. It may wait, it allocates, and it draws.
/// - Forbid: must not be held: waiting for the locks would break it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated that outlives the call.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MoveLayer`, `SizeLayer`
///
/// EXAMPLES:
/// ```zig
/// _ = lb.MoveSizeLayer(layer, 10, 0, 40, 20);
/// ```
pub fn MoveSizeLayer(lb: *LayersBase, layer: *Layer, dx: i32, dy: i32, dw: i32, dh: i32) bool {
    _locks.holdAll(lb, layer.info);
    defer _locks.releaseAll(lb, layer.info);
    const gb = lb.graphics_base;
    const info = layer.info;
    layer.last_error = layers.LERR_OK;
    if (dx == 0 and dy == 0 and dw == 0 and dh == 0) return true;

    const old = layer.bounds;
    const new = Rect{
        .min_x = old.min_x + dx,
        .min_y = old.min_y + dy,
        .max_x = old.max_x + dx + dw,
        .max_y = old.max_y + dy + dh,
    };
    if (new.isEmpty()) {
        layer.last_error = layers.LERR_BAD_BOUNDS;
        return false;
    }

    // What it will be able to see when it gets there.
    const seen = seenAt(lb, layer, new) orelse {
        layer.last_error = layers.LERR_NO_MEMORY;
        return false;
    };
    defer gb.DisposeRegion(seen);

    if (!keepBehind(lb, layer, Rect.intersect(new, info.bounds))) {
        layer.last_error = layers.LERR_NO_MEMORY;
        return false;
    }

    // What it has at the new place, once the pixels have been dealt with.
    // `retile` takes the difference between this and what it can really
    // see, and that difference is the damage - so getting this right is
    // the whole of it.
    var have: *graphics.Region = undefined;
    if (layer.flags & layers.LAYERSMART != 0) {
        // Everything into its own keeping, as though it had been covered
        // completely. The move then has nothing left on the display to
        // preserve, and what it can see at the new place is copied back
        // out of the keeping by the retile.
        const nothing = gb.NewRegion() orelse {
            layer.last_error = layers.LERR_NO_MEMORY;
            return false;
        };
        if (!smart.regather(lb, layer, nothing)) {
            gb.DisposeRegion(nothing);
            layer.last_error = layers.LERR_NO_MEMORY;
            return false;
        }
        have = nothing;
    } else {
        // What it can see now, moved, and still visible there.
        have = _layerinfo.copyRegion(gb, layer.visible) orelse {
            layer.last_error = layers.LERR_NO_MEMORY;
            return false;
        };
        gb.OffsetRegion(have, dx, dy);
        if (!gb.AndRegionRegion(seen, have)) {
            gb.DisposeRegion(have);
            layer.last_error = layers.LERR_NO_MEMORY;
            return false;
        }
        carry(lb, layer, have, dx, dy);
    }

    layer.bounds = new;
    // The RastPort's coordinates start at the layer's corner, so a move
    // leaves them alone and a resize changes what they may reach.
    const own = if (layer.super != null) super.extent(layer) else Rect{ .max_x = new.width(), .max_y = new.height() };
    const clip = [_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&own) }, .{} };
    gb.SetRPAttrs(layer.rp, &clip);
    // A layer's own coordinates travel with it, so what it is owed needs
    // no moving - but a smaller layer cannot owe what it no longer has.
    _ = gb.AndRectRegion(layer.damage, &own);

    gb.DisposeRegion(layer.visible);
    layer.visible = have;

    if (!tile.retile(lb, info)) {
        layer.last_error = layers.LERR_NO_MEMORY;
        return false;
    }

    // What a growing layer gained has never held anything. A simple layer
    // is told about it as damage, and the retile has painted it on the way
    // past; a smart one is told about nothing, so its new room is painted
    // here - including the part of it that is already covered, which goes
    // into its keeping because the paint goes through its RastPort.
    if (layer.flags & layers.LAYERSMART != 0) {
        const was = Rect{ .max_x = old.width(), .max_y = old.height() };
        if (dw > 0) backfill.fill(lb, layer, .{ .min_x = was.max_x, .max_x = own.max_x, .max_y = own.max_y });
        if (dh > 0) backfill.fill(lb, layer, .{ .min_y = was.max_y, .max_x = @min(was.max_x, own.max_x), .max_y = own.max_y });
    }
    return true;
}

/// What the layer would be able to see at `where`: that rectangle, less
/// every layer in front of it. The same answer `retile` works out, needed
/// here before the move so that the pixels can be put in the right place.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer being moved.
/// - `where` - where it is going, in the display's coordinates.
fn seenAt(lb: *LayersBase, layer: *Layer, where: Rect) ?*graphics.Region {
    const gb = lb.graphics_base;
    const seen = gb.NewRegion() orelse return null;
    // Only what is on the display: a layer may hang off the edge.
    const on_screen = Rect.intersect(where, layer.info.bounds);
    if (!gb.OrRectRegion(seen, &on_screen)) {
        gb.DisposeRegion(seen);
        return null;
    }
    var it = layer.info.layers.iterator();
    while (it.next()) |node| {
        const other: *Layer = @fieldParentPtr("node", node);
        if (other == layer) break; // everything past this one is behind it
        if (!gb.ClearRectRegion(seen, &other.bounds)) {
            gb.DisposeRegion(seen);
            return null;
        }
    }
    return seen;
}

/// Every layer behind `layer` that keeps what is covered puts away, now,
/// what `layer` will cover at `where`.
///
/// The display still shows their own pixels there. Once the moved layer's
/// pixels are carried across - or brought back out of its keeping by the
/// retile, which reaches it before the layers behind it - the display
/// holds the moved layer's instead, and a keeping filled from it then would
/// be a picture of the wrong layer.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer being moved.
/// - `where` - where it is going, cut to the display.
fn keepBehind(lb: *LayersBase, layer: *Layer, where: Rect) bool {
    const gb = lb.graphics_base;
    var behind = false;
    var it = layer.info.layers.iterator();
    while (it.next()) |node| {
        const other: *Layer = @fieldParentPtr("node", node);
        if (other == layer) {
            behind = true;
            continue;
        }
        if (!behind or other.flags & (layers.LAYERSMART | layers.LAYERSUPER) == 0) continue;
        const seen = _layerinfo.copyRegion(gb, other.visible) orelse return false;
        if (!gb.ClearRectRegion(seen, &where)) {
            gb.DisposeRegion(seen);
            return false;
        }
        const ok = if (other.flags & layers.LAYERSUPER != 0) super.resquare(lb, other, seen) else smart.regather(lb, other, seen);
        if (!ok) {
            gb.DisposeRegion(seen);
            return false;
        }
        gb.DisposeRegion(other.visible);
        other.visible = seen;
    }
    return true;
}

/// Copy the pixels that can travel, across the display.
///
/// `where` is where they are going, in the display's coordinates; they
/// come from the same rectangles less the delta. A layer moved over itself
/// has pieces whose new place is another piece's old one, and no order of
/// copying them one by one is right for every shape - the pieces are not
/// laid out in bands, so a move right and up writes a piece over its
/// neighbour before the neighbour has been read. So they all go into a
/// scratch bitmap first and come out of it after. Without the memory for
/// one, they are walked away from the direction of travel, which is right
/// for a layer that is one rectangle.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer being moved.
/// - `where` - the pixels' new places, in the display's coordinates.
/// - `dx` - how far they go across.
/// - `dy` - how far they go down.
fn carry(lb: *LayersBase, layer: *Layer, where: *graphics.Region, dx: i32, dy: i32) void {
    const gb = lb.graphics_base;
    const info = layer.info;
    const dest = info.display_rp orelse return;

    const n = gb.RegionRectangles(where, null, 0);
    if (n == 0) return;
    const bytes = n * @sizeOf(Rect);
    const mem = lb.sys_base.AllocPooled(info.pool, bytes) orelse return;
    defer lb.sys_base.FreePooled(info.pool, mem, bytes);
    const rects: [*]Rect = @ptrCast(@alignCast(mem));
    _ = gb.RegionRectangles(where, rects, n);

    if (n > 1) {
        // Where they come from, all of it.
        var box = rects[0];
        for (rects[1..n]) |r| {
            box = .{
                .min_x = @min(box.min_x, r.min_x),
                .min_y = @min(box.min_y, r.min_y),
                .max_x = @max(box.max_x, r.max_x),
                .max_y = @max(box.max_y, r.max_y),
            };
        }
        const tags = [_]TagItem{
            .{ .tag = graphics.BMTAG_Width, .data = @intCast(box.width()) },
            .{ .tag = graphics.BMTAG_Height, .data = @intCast(box.height()) },
            .{ .tag = graphics.BMTAG_Format, .data = @intFromEnum(info.surface.format) },
            .{},
        };
        if (gb.AllocBitMapTagList(&tags)) |scratch| {
            defer gb.FreeBitMap(scratch);
            for (rects[0..n]) |r| {
                _ = gb.BltBitMap(info.surface, r.min_x - dx, r.min_y - dy, scratch, r.min_x - box.min_x, r.min_y - box.min_y, r.width(), r.height());
            }
            for (rects[0..n]) |r| {
                gb.BltBitMapRastPort(scratch, r.min_x - box.min_x, r.min_y - box.min_y, dest, r.min_x, r.min_y, r.width(), r.height());
            }
            return;
        }
    }

    // Sorted by where they lie, so going forwards moves a piece up or left
    // and going backwards moves it down or right.
    const backwards = dy > 0 or (dy == 0 and dx > 0);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const r = rects[if (backwards) n - 1 - i else i];
        gb.BltBitMapRastPort(info.surface, r.min_x - dx, r.min_y - dy, dest, r.min_x, r.min_y, r.width(), r.height());
    }
}
