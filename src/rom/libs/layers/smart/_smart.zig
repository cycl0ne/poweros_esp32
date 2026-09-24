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
//! worked out from the difference. Where a new covered piece gets its
//! contents from is the only fiddly part - some of it was visible a moment
//! ago and is still on the display, and some of it was already covered and
//! is in a surface that is about to go.

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
const LayersBase = @import("../layers.zig").LayersBase;

/// A surface to keep one covered piece in, in the display's format.
///
/// INPUTS:
/// - `gb` - graphics.library, to allocate the surface.
/// - `info` - the display, whose format it takes.
/// - `area` - the piece, whose size it takes.
fn keepingSurface(gb: *GraphicsBase, info: *LayerInfo, area: Rect) ?*rtg.Surface {
    const tags = [_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = @intCast(area.width()) },
        .{ .tag = graphics.BMTAG_Height, .data = @intCast(area.height()) },
        .{ .tag = graphics.BMTAG_Format, .data = @intFromEnum(info.surface.format) },
        .{},
    };
    return gb.AllocBitMapTagList(&tags);
}

/// Every kept piece given back, with nothing put anywhere. For a layer
/// that is going away, where there is no longer anything to put it on.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer going away.
pub fn dropKept(lb: *LayersBase, layer: *Layer) void {
    const gb = lb.graphics_base;
    const sys = lb.sys_base;
    var at = layer.kept;
    while (at) |k| {
        const next = k.next;
        gb.FreeBitMap(k.surface);
        sys.FreePooled(layer.info.pool, k, @sizeOf(Kept));
        at = next;
    }
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
    putBack(lb, layer, seen);
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
    const sys = lb.sys_base;
    const info = layer.info;
    const bx = layer.bounds.min_x;
    const by = layer.bounds.min_y;
    const own = Rect{ .max_x = layer.bounds.width(), .max_y = layer.bounds.height() };

    // Everything below works in the layer's own coordinates, because that
    // is what a kept piece is in and what the layer draws in.
    const now_visible = info_mod.copyRegion(gb, seen) orelse return false;
    defer gb.DisposeRegion(now_visible);
    gb.OffsetRegion(now_visible, -bx, -by);

    const was_visible = info_mod.copyRegion(gb, layer.visible) orelse return false;
    defer gb.DisposeRegion(was_visible);
    gb.OffsetRegion(was_visible, -bx, -by);

    // What is covered now: the whole layer less what it can see.
    const now_hidden = gb.NewRegion() orelse return false;
    defer gb.DisposeRegion(now_hidden);
    if (!gb.OrRectRegion(now_hidden, &own) or !gb.SubRegionRegion(now_visible, now_hidden)) return false;

    const hidden = takeRects(lb, info, now_hidden) orelse return false;
    defer dropRects(lb, info, hidden);

    // A surface for each covered piece, filled from wherever those pixels
    // are at this moment.
    var fresh: ?*Kept = null;
    var i: u32 = 0;
    while (i < hidden.n) : (i += 1) {
        const area = hidden.ptr[i];
        const surface = keepingSurface(gb, info, area) orelse {
            dropList(lb, layer, fresh);
            return false;
        };
        const node = info_mod.newKept(sys, info) orelse {
            gb.FreeBitMap(surface);
            dropList(lb, layer, fresh);
            return false;
        };
        node.* = .{ .next = fresh, .area = area, .surface = surface };
        fresh = node;

        // The part of it that is still on the display, because it was
        // visible until a moment ago.
        if (meeting(lb, area, was_visible)) |from_screen| {
            defer gb.DisposeRegion(from_screen);
            if (takeRects(lb, info, from_screen)) |parts| {
                defer dropRects(lb, info, parts);
                var j: u32 = 0;
                while (j < parts.n) : (j += 1) {
                    const p = parts.ptr[j];
                    _ = gb.BltBitMap(info.surface, p.min_x + bx, p.min_y + by, surface, p.min_x - area.min_x, p.min_y - area.min_y, p.width(), p.height());
                }
            }
        }

        // And the part that was already covered, which is in a surface
        // that is about to be given back.
        var old = layer.kept;
        while (old) |k| : (old = k.next) {
            const meet = Rect.intersect(area, k.area);
            if (meet.isEmpty()) continue;
            _ = gb.BltBitMap(k.surface, meet.min_x - k.area.min_x, meet.min_y - k.area.min_y, surface, meet.min_x - area.min_x, meet.min_y - area.min_y, meet.width(), meet.height());
        }
    }

    layer.pending = fresh;
    layer.pending_made = true;
    return true;
}

/// The second half: what was covered and is not any more goes back on the
/// display from the old keeping, which is the whole point - the layer is
/// never asked to draw it again - and the list `keepCovered` made replaces
/// it.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - a smart layer.
/// - `seen` - what it can see now.
pub fn putBack(lb: *LayersBase, layer: *Layer, seen: *graphics.Region) void {
    const gb = lb.graphics_base;
    const info = layer.info;
    const bx = layer.bounds.min_x;
    const by = layer.bounds.min_y;
    if (!layer.pending_made) return;
    layer.pending_made = false;

    const now_visible = info_mod.copyRegion(gb, seen) orelse {
        dropKept(lb, layer);
        layer.kept = layer.pending;
        layer.pending = null;
        return;
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
                gb.BltBitMapRastPort(k.surface, p.min_x - k.area.min_x, p.min_y - k.area.min_y, rp, p.min_x + bx, p.min_y + by, p.width(), p.height());
            }
        }
    }

    dropKept(lb, layer);
    layer.kept = layer.pending;
    layer.pending = null;
}

/// A half-built list of kept pieces, for when something ran out part way.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer.
/// - `from` - the first piece of the list.
fn dropList(lb: *LayersBase, layer: *Layer, from: ?*Kept) void {
    const gb = lb.graphics_base;
    var at = from;
    while (at) |k| {
        const next = k.next;
        gb.FreeBitMap(k.surface);
        lb.sys_base.FreePooled(layer.info.pool, k, @sizeOf(Kept));
        at = next;
    }
}
