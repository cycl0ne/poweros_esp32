// SPDX-License-Identifier: MPL-2.0
//! Keeping a covered window's pixels, and putting them back.
//!
//! With `LAYERSIMPLE` a covered piece of a layer is simply not written:
//! the pixels go nowhere and the layer is asked to draw them again when it
//! is uncovered. `LAYERSMART` keeps them instead. Each covered piece gets a
//! surface of its own, the layer's drawing calls land in it through a clip
//! target exactly as the visible pieces land on the display, and when the
//! piece is uncovered the surface is copied back. The layer never learns
//! that any of it happened and is never asked to redraw.
//!
//! **A piece and not a window**, because a window that is covered by a
//! corner should pay for a corner. On a 1024x600 display in rgb565 a whole
//! window's worth is 1.2 MB of the eight the machine has.
//!
//! The work is all in one place: when the tiling changes, what a layer can
//! see changes with it, and both the keeping and the putting back are
//! worked out from the difference.
//!
//! **A change costs what it changes.** A surface stays for as long as any
//! of what was put in it is still covered: a piece is a part of a store,
//! several pieces may share one, and the last to go frees it. So when a
//! window is dragged over another a step at a time, the one behind keeps
//! the surfaces it has, gives back the strip the step uncovers and puts
//! away the strip it covers - a few rows of pixels a step, not the whole
//! of what it has covered. The pieces that pile up that way, and the
//! surfaces that end up mostly given back, are gathered into fresh ones
//! now and then (`compact`).

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;
const rtg = sdk.rtg;
const ExecBase = sdk.interface.exec.ExecBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const Rect = graphics.Rect;
const TagItem = sdk.utility.TagItem;

const info_mod = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = info_mod.LayerInfo;
const Layer = info_mod.Layer;
const Kept = info_mod.Kept;
const Store = info_mod.Store;
const LayersBase = @import("../layers.zig").LayersBase;

/// A store for the covered part `area` of a layer, in the display's
/// format, with no piece in it yet.
///
/// INPUTS:
/// - `lb` - the library.
/// - `info` - the display, whose format and pool it takes.
/// - `area` - the part, in the layer's coordinates, whose size it takes.
fn newStore(lb: *LayersBase, info: *LayerInfo, area: Rect) ?*Store {
    const gb = lb.graphics_base;
    const tags = [_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = @intCast(area.width()) },
        .{ .tag = graphics.BMTAG_Height, .data = @intCast(area.height()) },
        .{ .tag = graphics.BMTAG_Format, .data = @intFromEnum(info.surface.format) },
        .{},
    };
    const surface = gb.AllocBitMapTagList(&tags) orelse return null;
    const store = info_mod.newStore(lb.sys_base, info) orelse {
        gb.FreeBitMap(surface);
        return null;
    };
    store.* = .{ .surface = surface, .x = area.min_x, .y = area.min_y };
    return store;
}

/// A piece of `store`, put at the head of `list`.
fn addPiece(lb: *LayersBase, info: *LayerInfo, list: *?*Kept, area: Rect, store: *Store) bool {
    const node = info_mod.newKept(lb.sys_base, info) orelse return false;
    node.* = .{ .next = list.*, .area = area, .store = store };
    store.refs += 1;
    list.* = node;
    return true;
}

/// One piece given back, and its store with it when it was the last.
fn dropPiece(lb: *LayersBase, info: *LayerInfo, piece: *Kept) void {
    const store = piece.store;
    store.refs -= 1;
    if (store.refs == 0) {
        lb.graphics_base.FreeBitMap(store.surface);
        lb.sys_base.FreePooled(info.pool, store, @sizeOf(Store));
    }
    lb.sys_base.FreePooled(info.pool, piece, @sizeOf(Kept));
}

/// Every kept piece given back, with nothing put anywhere. For a layer
/// that is going away, where there is no longer anything to put it on.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer going away.
pub fn dropKept(lb: *LayersBase, layer: *Layer) void {
    dropList(lb, layer, layer.kept);
    layer.kept = null;
}

/// The rectangles of a region, taken from the pool. The caller gives them
/// back with `dropRects`.
const Rects = struct {
    ptr: [*]Rect = undefined,
    n: u32 = 0,
    bytes: usize = 0,
};

/// The rectangles of a region, in room taken from the display's pool.
///
/// INPUTS:
/// - `lb` - the library.
/// - `info` - the display, whose pool the room comes from.
/// - `region` - the region.
fn takeRects(lb: *LayersBase, info: *LayerInfo, region: *graphics.Region) ?Rects {
    const gb = lb.graphics_base;
    const n = gb.RegionRectangles(region, null, 0);
    if (n == 0) return Rects{};
    const bytes = n * @sizeOf(Rect);
    const mem = lb.sys_base.AllocPooled(info.pool, bytes) orelse return null;
    const ptr: [*]Rect = @ptrCast(@alignCast(mem));
    _ = gb.RegionRectangles(region, ptr, n);
    return Rects{ .ptr = ptr, .n = n, .bytes = bytes };
}

/// Gives back what `takeRects` took.
///
/// INPUTS:
/// - `lb` - the library.
/// - `info` - the display.
/// - `r` - what `takeRects` gave.
fn dropRects(lb: *LayersBase, info: *LayerInfo, r: Rects) void {
    if (r.bytes != 0) lb.sys_base.FreePooled(info.pool, r.ptr, r.bytes);
}

/// A region holding one rectangle, narrowed to another region. Null if
/// there was no memory; empty if the two do not meet.
///
/// INPUTS:
/// - `lb` - the library.
/// - `area` - the rectangle.
/// - `within` - the region to narrow it to.
fn meeting(lb: *LayersBase, area: Rect, within: *graphics.Region) ?*graphics.Region {
    const gb = lb.graphics_base;
    const region = gb.NewRegion() orelse return null;
    if (!gb.OrRectRegion(region, &area) or !gb.AndRegionRegion(within, region)) {
        gb.DisposeRegion(region);
        return null;
    }
    return region;
}

/// What a layer keeps, worked out again for a tiling that has changed:
/// `keepCovered`, then `putBack`.
///
/// `seen` is what the layer can see now, in the display's coordinates;
/// `layer.visible` is still what it could see before, and `layer.kept` is
/// still what it was keeping. Afterwards every piece that is covered now
/// has its pixels somewhere, and every piece that was covered and is not
/// any more has been put back on the display.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - a smart layer.
/// - `seen` - what it can see now.
pub fn regather(lb: *LayersBase, layer: *Layer, seen: *graphics.Region) bool {
    if (!keepCovered(lb, layer, seen)) return false;
    if (putBack(lb, layer, seen)) |owed| lb.graphics_base.DisposeRegion(owed);
    return true;
}

/// The first half: every piece covered now gets a surface, filled from the
/// display where it was visible until now and from the old keeping where it
/// was already covered. The new list goes to `layer.pending`; nothing is
/// drawn on the display, so every layer can do this before any of them puts
/// anything back - which is what keeps one layer's pixels out of another's
/// keeping.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - a smart layer.
/// - `seen` - what it can see now.
///
/// RESULT:
/// False without memory.
pub fn keepCovered(lb: *LayersBase, layer: *Layer, seen: *graphics.Region) bool {
    const gb = lb.graphics_base;
    const info = layer.info;
    const bx = layer.bounds.min_x;
    const by = layer.bounds.min_y;
    const own = Rect{ .max_x = layer.bounds.width(), .max_y = layer.bounds.height() };

    // Everything below works in the layer's own coordinates, because that
    // is what a kept piece is in and what the layer draws in.
    const now_visible = info_mod.copyRegion(gb, seen) orelse return false;
    defer gb.DisposeRegion(now_visible);
    gb.OffsetRegion(now_visible, -bx, -by);

    // What is covered now: the whole layer less what it can see.
    const now_hidden = gb.NewRegion() orelse return false;
    defer gb.DisposeRegion(now_hidden);
    if (!gb.OrRectRegion(now_hidden, &own) or !gb.SubRegionRegion(now_visible, now_hidden)) return false;

    var fresh: ?*Kept = null;
    var count: u32 = 0;

    // What it keeps already, as far as it is still covered: the same
    // pixels, in the same stores - nothing copied.
    var had = layer.kept;
    while (had) |k| : (had = k.next) {
        const still = meeting(lb, k.area, now_hidden) orelse return failed(lb, layer, fresh);
        defer gb.DisposeRegion(still);
        const parts = takeRects(lb, info, still) orelse return failed(lb, layer, fresh);
        defer dropRects(lb, info, parts);
        var i: u32 = 0;
        while (i < parts.n) : (i += 1) {
            if (!addPiece(lb, info, &fresh, parts.ptr[i], k.store)) return failed(lb, layer, fresh);
            count += 1;
        }
    }

    // What it could see until now and is covered now: off the display,
    // which still shows it, into stores of its own. What is covered now
    // and was neither visible nor kept - the new part of a layer that has
    // just grown, or anything once a keeping had to be dropped - has no
    // pixels anywhere, and keeping a surface for it would keep whatever
    // was in that memory. It is not kept: `putBack` then reports it as
    // owed and the layer is asked to draw it.
    const newly = info_mod.copyRegion(gb, layer.visible) orelse return failed(lb, layer, fresh);
    defer gb.DisposeRegion(newly);
    gb.OffsetRegion(newly, -bx, -by);
    if (!gb.AndRegionRegion(now_hidden, newly)) return failed(lb, layer, fresh);
    const covered = takeRects(lb, info, newly) orelse return failed(lb, layer, fresh);
    defer dropRects(lb, info, covered);
    var i: u32 = 0;
    while (i < covered.n) : (i += 1) {
        const area = covered.ptr[i];
        const store = newStore(lb, info, area) orelse return failed(lb, layer, fresh);
        if (!addPiece(lb, info, &fresh, area, store)) {
            gb.FreeBitMap(store.surface);
            lb.sys_base.FreePooled(info.pool, store, @sizeOf(Store));
            return failed(lb, layer, fresh);
        }
        count += 1;
        _ = gb.BltBitMap(info.surface, area.min_x + bx, area.min_y + by, store.surface, 0, 0, area.width(), area.height());
    }

    // Gathered into fresh stores when the pieces have piled up or the
    // stores are mostly given back; kept as they are when that cannot be
    // had. The area they cover is what is covered now and has pixels
    // somewhere: what was visible or kept until now.
    if (count > pieces_before_gathering or wasteful(info, fresh)) {
        const sources = info_mod.copyRegion(gb, layer.visible) orelse return keepAsItIs(layer, fresh);
        defer gb.DisposeRegion(sources);
        gb.OffsetRegion(sources, -bx, -by);
        var old = layer.kept;
        while (old) |k| : (old = k.next) {
            if (!gb.OrRectRegion(sources, &k.area)) return keepAsItIs(layer, fresh);
        }
        if (!gb.AndRegionRegion(now_hidden, sources)) return keepAsItIs(layer, fresh);
        if (compact(lb, info, fresh, count, sources)) |gathered| fresh = gathered;
    }

    layer.pending = fresh;
    layer.pending_made = true;
    return true;
}

/// `keepCovered` done without gathering, which there was no memory for.
fn keepAsItIs(layer: *Layer, fresh: ?*Kept) bool {
    layer.pending = fresh;
    layer.pending_made = true;
    return true;
}

/// Whether the stores of `list` hold more pixels nobody keeps any more
/// than pixels kept, past a small allowance.
fn wasteful(info: *LayerInfo, list: ?*Kept) bool {
    // In 32 bits: a display's worth is well under a million pixels.
    info.visit +%= 1;
    var kept_pixels: u32 = 0;
    var store_pixels: u32 = 0;
    var at = list;
    while (at) |k| : (at = k.next) {
        kept_pixels +|= @as(u32, @intCast(k.area.width())) *| @as(u32, @intCast(k.area.height()));
        if (k.store.visit == info.visit) continue;
        k.store.visit = info.visit;
        store_pixels +|= @as(u32, k.store.surface.width) *| @as(u32, k.store.surface.height);
    }
    return store_pixels > (kept_pixels *| 2) +| pixels_before_gathering;
}

/// `keepCovered` giving up: what it had made so far given back, and false.
fn failed(lb: *LayersBase, layer: *Layer, made: ?*Kept) bool {
    dropList(lb, layer, made);
    return false;
}

/// Pieces past this many are gathered when they are many more than the
/// covered area needs.
const pieces_before_gathering = 16;
/// Stores holding more than this many pixels nobody keeps any more are
/// gathered when that is more than what is kept.
const pixels_before_gathering = 64 * 64;

/// The pieces of `list` gathered into as few fresh stores as `area` - the
/// region they cover - takes, filled from the old ones, when there are
/// more than twice as many pieces as that or the stores hold more pixels
/// given back than kept. A window dragged over another leaves a strip
/// piece behind at each step and stores that shrink, and this is what
/// keeps both bounded. The new list on success, the old one then given
/// back; null when nothing needed doing or there was no memory, and the
/// old list stands.
fn compact(lb: *LayersBase, info: *LayerInfo, list: ?*Kept, count: u32, area_region: *graphics.Region) ?*Kept {
    const gb = lb.graphics_base;
    if (count == 0) return null;
    const rects = takeRects(lb, info, area_region) orelse return null;
    defer dropRects(lb, info, rects);
    if (!wasteful(info, list) and count <= 2 * rects.n) return null;

    var gathered: ?*Kept = null;
    var i: u32 = 0;
    while (i < rects.n) : (i += 1) {
        const area = rects.ptr[i];
        const store = newStore(lb, info, area) orelse {
            dropPieces(lb, info, gathered);
            return null;
        };
        if (!addPiece(lb, info, &gathered, area, store)) {
            gb.FreeBitMap(store.surface);
            lb.sys_base.FreePooled(info.pool, store, @sizeOf(Store));
            dropPieces(lb, info, gathered);
            return null;
        }
        var at = list;
        while (at) |k| : (at = k.next) {
            const meet = Rect.intersect(area, k.area);
            if (meet.isEmpty()) continue;
            _ = gb.BltBitMap(k.store.surface, meet.min_x - k.store.x, meet.min_y - k.store.y, store.surface, meet.min_x - area.min_x, meet.min_y - area.min_y, meet.width(), meet.height());
        }
    }
    dropPieces(lb, info, list);
    return gathered;
}

/// The second half: what was covered and is not any more goes back on the
/// display from the old keeping, which is the whole point - the layer is
/// usually never asked to draw it again - and the list `keepCovered` made
/// replaces it.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - a smart layer.
/// - `seen` - what it can see now.
///
/// RESULT:
/// What the layer can see now, could not see before, and had no kept
/// pixels for, in the layer's own coordinates; null when there is none.
/// The caller owns it: that area is the layer's damage, and it is owed a
/// redraw for it. A keeping that had to be dropped for want of memory
/// comes out here, which is what keeps another window's pixels off a
/// display this one is now showing.
pub fn putBack(lb: *LayersBase, layer: *Layer, seen: *graphics.Region) ?*graphics.Region {
    const gb = lb.graphics_base;
    const info = layer.info;
    const bx = layer.bounds.min_x;
    const by = layer.bounds.min_y;

    // What it can see now and could not see before. Everything put back
    // below is taken off this again, and what is left is owed.
    var owed = newlyVisible(lb, layer, seen);

    if (!layer.pending_made) return dropIfEmpty(gb, owed);
    layer.pending_made = false;

    const now_visible = info_mod.copyRegion(gb, seen) orelse {
        dropKept(lb, layer);
        layer.kept = layer.pending;
        layer.pending = null;
        return dropIfEmpty(gb, owed);
    };
    defer gb.DisposeRegion(now_visible);
    gb.OffsetRegion(now_visible, -bx, -by);

    const dest = info.display_rp;
    var old = layer.kept;
    while (old) |k| : (old = k.next) {
        const back = meeting(lb, k.area, now_visible) orelse continue;
        defer gb.DisposeRegion(back);
        const parts = takeRects(lb, info, back) orelse continue;
        defer dropRects(lb, info, parts);
        var j: u32 = 0;
        while (j < parts.n) : (j += 1) {
            const p = parts.ptr[j];
            if (dest) |rp| {
                gb.BltBitMapRastPort(k.store.surface, p.min_x - k.store.x, p.min_y - k.store.y, rp, p.min_x + bx, p.min_y + by, p.width(), p.height());
            }
            // Those pixels are there: nobody is owed them.
            if (owed) |region| {
                if (!gb.ClearRectRegion(region, &p)) {
                    gb.DisposeRegion(region);
                    owed = null;
                }
            }
        }
    }

    dropKept(lb, layer);
    layer.kept = layer.pending;
    layer.pending = null;
    return dropIfEmpty(gb, owed);
}

/// What a layer can see now and could not see before, in its own
/// coordinates. Null without the memory to work it out, which leaves the
/// caller owing nothing - the same as it owed before this existed.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer.
/// - `seen` - what it can see now, in the display's coordinates.
fn newlyVisible(lb: *LayersBase, layer: *Layer, seen: *graphics.Region) ?*graphics.Region {
    const gb = lb.graphics_base;
    const fresh = info_mod.copyRegion(gb, seen) orelse return null;
    if (!gb.SubRegionRegion(layer.visible, fresh)) {
        gb.DisposeRegion(fresh);
        return null;
    }
    gb.OffsetRegion(fresh, -layer.bounds.min_x, -layer.bounds.min_y);
    return fresh;
}

/// The region, or null and given back when there is nothing in it: a
/// caller that is owed nothing should not have a region to dispose of.
fn dropIfEmpty(gb: *GraphicsBase, region: ?*graphics.Region) ?*graphics.Region {
    const it = region orelse return null;
    if (!info_mod.isEmpty(gb, it)) return it;
    gb.DisposeRegion(it);
    return null;
}

/// What `keepCovered` put aside, given back without using it.
///
/// Nothing it made has reached the display or replaced what the layer
/// already keeps, so this puts the layer back exactly as it was.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer that put it aside.
pub fn dropPending(lb: *LayersBase, layer: *Layer) void {
    dropList(lb, layer, layer.pending);
    layer.pending = null;
    layer.pending_made = false;
}

/// A half-built list of kept pieces, for when something ran out part way.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer.
/// - `from` - the first piece of the list.
fn dropList(lb: *LayersBase, layer: *Layer, from: ?*Kept) void {
    dropPieces(lb, layer.info, from);
}

/// Every piece of a list given back, and each store with its last piece.
fn dropPieces(lb: *LayersBase, info: *LayerInfo, from: ?*Kept) void {
    var at = from;
    while (at) |k| {
        const next = k.next;
        dropPiece(lb, info, k);
        at = next;
    }
}
