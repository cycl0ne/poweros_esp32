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
//!
//! The layers made to move with this one (`LATAG_MovesWith`) go in the
//! same pass: each works out what it will see at its new place with the
//! others already there, and the pixels of all of them travel in one
//! carry. Two passes would leave a moment with one moved and the other
//! not, and whatever either uncovers of the other in that moment is lost.

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
/// Every layer made to move with this one (`LATAG_MovesWith`) moves and
/// sizes by the same amounts in the same pass. Where one of them covered
/// another before, it covers it after, so none is uncovered by another on
/// the way and none owes a redraw for it.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the display's layers.
/// - Interrupts: no. It may wait, it allocates, and it draws.
/// - Locks: no spinlock may be held: it waits for locks.
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
    const sys = lb.sys_base;
    const info = layer.info;
    layer.last_error = layers.LERR_OK;
    if (dx == 0 and dy == 0 and dw == 0 and dh == 0) return true;

    // The layer, and every layer that moves with it: they all go the same
    // way in the one pass.
    var count: usize = 1;
    var all = info.layers.iterator();
    while (all.next()) |node| {
        const other: *Layer = @fieldParentPtr("node", node);
        if (other.moves_with == layer and other != layer) count += 1;
    }
    const room = count * @sizeOf(Member);
    const memory = sys.AllocPooled(info.pool, room) orelse {
        layer.last_error = layers.LERR_NO_MEMORY;
        return false;
    };
    defer sys.FreePooled(info.pool, memory, room);
    const group = @as([*]Member, @ptrCast(@alignCast(memory)))[0..count];
    group[0] = .{ .layer = layer };
    var filled: usize = 1;
    all = info.layers.iterator();
    while (all.next()) |node| {
        const other: *Layer = @fieldParentPtr("node", node);
        if (other.moves_with != layer or other == layer) continue;
        group[filled] = .{ .layer = other };
        filled += 1;
    }
    defer for (group) |member| {
        if (member.seen) |region| gb.DisposeRegion(region);
        if (member.have) |region| gb.DisposeRegion(region);
    };
    for (group) |*member| {
        const old = member.layer.bounds;
        member.old = old;
        member.new = .{
            .min_x = old.min_x + dx,
            .min_y = old.min_y + dy,
            .max_x = old.max_x + dx + dw,
            .max_y = old.max_y + dy + dh,
        };
        if (member.new.isEmpty()) {
            layer.last_error = layers.LERR_BAD_BOUNDS;
            return false;
        }
    }

    // What each will be able to see when it gets there.
    for (group) |*member| {
        member.seen = seenAt(lb, group, member) orelse {
            layer.last_error = layers.LERR_NO_MEMORY;
            return false;
        };
    }

    // Everything that is going to be needed is got before anything is
    // changed, and only when it has all been got does any of it happen.
    // A move half done is worse than a move not done: the layers would
    // be describing two different displays, and whatever drew next would
    // draw through the disagreement.
    //
    // What can run out is the keeping - one surface the size of a layer,
    // for each moving one and for each one behind them that will be
    // covered - and there is not always a block that big to be had when a
    // window is holding a large picture. Then the move goes ahead with no
    // keeping for anybody, and what none of them can see is drawn again
    // instead of being put back. Pixels that are redrawn cost a redraw; a
    // move abandoned half way costs the display.
    var keeping = reserveBehind(lb, group);

    // What each will have at the new place, once the pixels have been
    // dealt with. `retile` takes the difference between this and what it
    // can really see, and that difference is the damage - so getting
    // this right is the whole of it.
    for (group) |*member| {
        const moving = member.layer;
        if (moving.flags & layers.LAYERSMART != 0) {
            // A moving smart layer puts everything aside, as though it had
            // been covered all over. The move then has nothing left on the
            // display to preserve, and what it can see at the new place
            // comes back out of the keeping in the retile - so what it has
            // to begin with is nothing.
            member.have = gb.NewRegion();
            if (member.have) |have| {
                if (keeping and !smart.keepCovered(lb, moving, have)) keeping = false;
            }
        } else if (_layerinfo.copyRegion(gb, moving.visible)) |have| {
            // What it can see now, moved, and still visible there.
            member.have = have;
            gb.OffsetRegion(have, dx, dy);
            if (!gb.AndRegionRegion(member.seen.?, have)) {
                gb.DisposeRegion(have);
                member.have = null;
            }
        }
        if (member.have == null) return abandon(lb, group);
    }

    // Every simple one's pixels go the same way, so they travel in one
    // carry: moved one layer at a time, one would be written over where
    // another's still had to be read.
    const carried = gb.NewRegion() orelse return abandon(lb, group);
    defer gb.DisposeRegion(carried);
    for (group) |member| {
        if (member.layer.flags & layers.LAYERSMART != 0) continue;
        if (!gb.OrRegionRegion(member.have.?, carried)) return abandon(lb, group);
    }

    if (!keeping) {
        dropReserved(lb, group);
        for (group) |member| {
            smart.dropPending(lb, member.layer);
            smart.dropKept(lb, member.layer);
        }
        keepNothingBehind(lb, group);
    }

    // From here nothing can fail for want of memory, and the display is
    // taken from the shape it had to the shape it is going to have.
    commitBehind(lb, group);
    carry(lb, info, carried, dx, dy);
    // A smart one has nothing visible at `have`, so nothing is put back
    // and nothing can be owed: what it can see at the new place comes
    // back in the retile below.
    if (keeping) for (group) |member| {
        if (member.layer.flags & layers.LAYERSMART == 0) continue;
        if (smart.putBack(lb, member.layer, member.have.?)) |owed| gb.DisposeRegion(owed);
    };

    for (group) |*member| {
        const moving = member.layer;
        moving.bounds = member.new;
        // The RastPort's coordinates start at the layer's corner, so a move
        // leaves them alone and a resize changes what they may reach.
        const own = ownExtent(moving);
        const clip = [_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&own) }, .{} };
        gb.SetRPAttrs(moving.rp, &clip);
        // A layer's own coordinates travel with it, so what it is owed
        // needs no moving - but a smaller layer cannot owe what it no
        // longer has.
        _ = gb.AndRectRegion(moving.damage, &own);
        gb.DisposeRegion(moving.visible);
        moving.visible = member.have.?;
        member.have = null;
    }

    // The layers have moved: `bounds` above says so, and every layer has
    // been told. A retile that could not do all of it has still done
    // what it could, and there is no going back to where this started -
    // so what it reports is kept as the error to ask about, and the move
    // is reported as what it is, done. Saying it failed would leave the
    // caller believing the layer is where it was, drawing the old shape
    // through the new one's clipping.
    if (!tile.retile(lb, info)) layer.last_error = layers.LERR_NO_MEMORY;

    // What a layer behind was left owing, painted now that its clipping
    // is the new one.
    paintOwed(lb, group);

    // What a growing layer gained has never held anything. A simple layer
    // is told about it as damage, and the retile has painted it on the way
    // past; a smart one is told about nothing, so its new room is painted
    // here - including the part of it that is already covered, which goes
    // into its keeping because the paint goes through its RastPort.
    for (group) |member| {
        const moving = member.layer;
        if (moving.flags & layers.LAYERSMART == 0) continue;
        const own = ownExtent(moving);
        const was = Rect{ .max_x = member.old.width(), .max_y = member.old.height() };
        if (dw > 0) backfill.fill(lb, moving, .{ .min_x = was.max_x, .max_x = own.max_x, .max_y = own.max_y });
        if (dh > 0) backfill.fill(lb, moving, .{ .min_y = was.max_y, .max_x = @min(was.max_x, own.max_x), .max_y = own.max_y });
    }
    return true;
}

/// A layer that moves, and what the move works out for it on the way.
const Member = struct {
    layer: *Layer,
    /// Where it was and where it is going, in the display's coordinates.
    old: Rect = .{},
    new: Rect = .{},
    /// What it will be able to see there.
    seen: ?*graphics.Region = null,
    /// What it will have there once the pixels are dealt with; the
    /// layer's own from the moment it is in place.
    have: ?*graphics.Region = null,
};

/// Where a moving layer is going, or null for one that stays.
fn newOf(group: []const Member, layer: *const Layer) ?Rect {
    for (group) |member| {
        if (member.layer == layer) return member.new;
    }
    return null;
}

/// What a layer's RastPort may reach, in its own coordinates.
fn ownExtent(layer: *Layer) Rect {
    if (layer.super != null) return super.extent(layer);
    return .{ .max_x = layer.bounds.width(), .max_y = layer.bounds.height() };
}

/// A move given up before anything changed: what was put aside for it
/// given back, and the reason in the layer.
fn abandon(lb: *LayersBase, group: []const Member) bool {
    for (group) |member| smart.dropPending(lb, member.layer);
    dropReserved(lb, group);
    group[0].layer.last_error = layers.LERR_NO_MEMORY;
    return false;
}

/// What a moving layer would be able to see at its new place: that
/// rectangle, less every layer in front of it - where a layer in front is
/// moving too, at its own new place. The same answer `retile` works out,
/// needed here before the move so that the pixels can be put in the right
/// place.
///
/// INPUTS:
/// - `lb` - the library.
/// - `group` - every layer that moves.
/// - `member` - the one asked about.
///
/// RESULT:
/// A region in the display's coordinates, which the caller disposes of,
/// or null without memory.
fn seenAt(lb: *LayersBase, group: []const Member, member: *const Member) ?*graphics.Region {
    const gb = lb.graphics_base;
    const info = member.layer.info;
    const seen = gb.NewRegion() orelse return null;
    // Only what is on the display: a layer may hang off the edge.
    const on_screen = Rect.intersect(member.new, info.bounds);
    if (!gb.OrRectRegion(seen, &on_screen)) {
        gb.DisposeRegion(seen);
        return null;
    }
    var it = info.layers.iterator();
    while (it.next()) |node| {
        const other: *Layer = @fieldParentPtr("node", node);
        if (other == member.layer) break; // everything past this one is behind it
        const covers = newOf(group, other) orelse other.bounds;
        if (!gb.ClearRectRegion(seen, &covers)) {
            gb.DisposeRegion(seen);
            return null;
        }
    }
    return seen;
}

/// Every layer behind a moving one that keeps what is covered puts aside,
/// now, what the moving layers in front of it will cover at their new
/// places - and nothing of theirs has changed when this returns, either
/// way.
///
/// The display still shows their own pixels there. Once the moved layers'
/// pixels are carried across - or brought back out of their keeping by the
/// retile, which reaches them before the layers behind them - the display
/// holds the moved layers' instead, and a keeping filled from it then would
/// be a picture of the wrong layer.
///
/// INPUTS:
/// - `lb` - the library.
/// - `group` - every layer that moves.
///
/// RESULT:
/// False without the memory for all of it; what was put aside is then in
/// `next_visible` and pending, for `dropReserved` to give back.
fn reserveBehind(lb: *LayersBase, group: []const Member) bool {
    const gb = lb.graphics_base;
    const info = group[0].layer.info;
    // What the moving layers passed so far will cover where they are going.
    const covering = gb.NewRegion() orelse return false;
    defer gb.DisposeRegion(covering);
    var behind = false;
    var it = info.layers.iterator();
    while (it.next()) |node| {
        const other: *Layer = @fieldParentPtr("node", node);
        if (newOf(group, other)) |new| {
            behind = true;
            const there = Rect.intersect(new, info.bounds);
            if (!gb.OrRectRegion(covering, &there)) return false;
            continue;
        }
        if (!behind or other.flags & (layers.LAYERSMART | layers.LAYERSUPER) == 0) continue;
        const seen = _layerinfo.copyRegion(gb, other.visible) orelse return false;
        if (!gb.SubRegionRegion(covering, seen)) {
            gb.DisposeRegion(seen);
            return false;
        }
        const ok = if (other.flags & layers.LAYERSUPER != 0)
            super.saveCovered(lb, other, seen)
        else
            smart.keepCovered(lb, other, seen);
        if (!ok) {
            gb.DisposeRegion(seen);
            return false;
        }
        // Held for the second pass, which is the one that changes
        // anything.
        other.next_visible = seen;
    }
    return true;
}

/// What `reserveBehind` put aside, given back unused.
fn dropReserved(lb: *LayersBase, group: []const Member) void {
    const gb = lb.graphics_base;
    var it = group[0].layer.info.layers.iterator();
    while (it.next()) |node| {
        const other: *Layer = @fieldParentPtr("node", node);
        if (newOf(group, other) != null) continue;
        if (other.next_visible) |region| {
            gb.DisposeRegion(region);
            other.next_visible = null;
        }
        smart.dropPending(lb, other);
    }
}

/// What `reserveBehind` put aside, made what each layer behind has now.
fn commitBehind(lb: *LayersBase, group: []const Member) void {
    const gb = lb.graphics_base;
    var it = group[0].layer.info.layers.iterator();
    while (it.next()) |node| {
        const other: *Layer = @fieldParentPtr("node", node);
        if (newOf(group, other) != null) continue;
        const seen = other.next_visible orelse continue;
        other.next_visible = null;
        if (other.flags & layers.LAYERSUPER != 0) {
            _ = super.bringBack(lb, other, seen);
        } else if (smart.putBack(lb, other, seen)) |owed| {
            // Uncovered with nothing kept for it, because the keeping
            // was dropped for want of memory. It is owed a redraw, and
            // the display is showing a moved layer's pixels there until
            // it answers - so it is painted as well, once the retile
            // below has put the new clipping in place.
            if (gb.OrRegionRegion(owed, other.damage)) {
                other.flags |= layers.LAYERREFRESH;
                other.owed = owed;
            } else gb.DisposeRegion(owed);
        }
        gb.DisposeRegion(other.visible);
        other.visible = seen;
    }
}

/// What a layer that stayed was left owing, painted now that its
/// clipping is the new one.
fn paintOwed(lb: *LayersBase, group: []const Member) void {
    const gb = lb.graphics_base;
    var it = group[0].layer.info.layers.iterator();
    while (it.next()) |node| {
        const other: *Layer = @fieldParentPtr("node", node);
        if (newOf(group, other) != null) continue;
        const owed = other.owed orelse continue;
        other.owed = null;
        backfill.fillRegion(lb, other, owed);
        gb.DisposeRegion(owed);
    }
}

/// Every layer behind a moving one told to keep nothing, for a move that
/// is going ahead without any keeping at all: what none of them can see is
/// drawn again rather than put back.
fn keepNothingBehind(lb: *LayersBase, group: []const Member) void {
    var behind = false;
    var it = group[0].layer.info.layers.iterator();
    while (it.next()) |node| {
        const other: *Layer = @fieldParentPtr("node", node);
        if (newOf(group, other) != null) {
            behind = true;
            continue;
        }
        if (behind) smart.dropKept(lb, other);
    }
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
/// - `info` - the display.
/// - `where` - the pixels' new places, in the display's coordinates.
/// - `dx` - how far they go across.
/// - `dy` - how far they go down.
fn carry(lb: *LayersBase, info: *LayerInfo, where: *graphics.Region, dx: i32, dy: i32) void {
    const gb = lb.graphics_base;
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
