// SPDX-License-Identifier: MPL-2.0
//! Working out what each layer can see, and telling its RastPort.
//!
//! **This is the whole of the geometry**, and it is region arithmetic
//! rather than an algebra of its own. Walking the layers from front to
//! back, each one starts as its own rectangle and loses whatever the
//! layers in front of it have already claimed; what is left is what it can
//! see. Then it claims its own rectangle too, and the next one back is
//! worked out against the sum.
//!
//! That is the same answer an incrementally-split list of clip rectangles
//! gives, without the list: `region.zig` already has the one piece of
//! geometry it rests on - cutting one rectangle out of another - and it is
//! tested. What is left here is bookkeeping.
//!
//! The regions are in the **display's** coordinates, because that is the
//! space the layers are laid out in. A layer's clip targets are in the
//! **layer's**, because that is the space its program draws in, and the
//! difference between the two is the offset each target carries.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const layers = sdk.layers;
const ExecBase = sdk.interface.exec.ExecBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const Rect = graphics.Rect;
const TagItem = sdk.utility.TagItem;

const info_mod = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = info_mod.LayerInfo;
const Layer = info_mod.Layer;
const LayersBase = @import("../layers.zig").LayersBase;
const smart = @import("../smart/_smart.zig");
const backfill = @import("../backfill/_backfill.zig");
const super = @import("../super/_super.zig");

/// What a layer can see, in the layer's own coordinates and narrowed by
/// whatever else is asked for. The caller disposes of it.
///
/// `also` is another region in the layer's coordinates to keep inside -
/// the damage, for `BeginUpdate` - or null for all of it.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer.
/// - `also` - a region in the layer's coordinates to narrow to as well, or
///   null.
pub fn inLayerSpace(lb: *LayersBase, layer: *Layer, also: ?*graphics.Region) ?*graphics.Region {
    const gb = lb.graphics_base;
    const work = info_mod.copyRegion(gb, layer.visible) orelse return null;
    const ox, const oy = super.origin(layer);
    gb.OffsetRegion(work, -ox, -oy);
    // The program's own clip, which is why InstallClipRegion is a call
    // here rather than on the RastPort: only this library knows which
    // pieces of the layer went where, so only it can fold the two.
    if (layer.clip_region) |own| {
        if (!gb.AndRegionRegion(own, work)) {
            gb.DisposeRegion(work);
            return null;
        }
    }
    if (also) |narrow| {
        if (!gb.AndRegionRegion(narrow, work)) {
            gb.DisposeRegion(work);
            return null;
        }
    }
    return work;
}

/// Put a region, in the layer's coordinates, on the layer's RastPort as
/// the places it may draw. What was there is freed.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer.
/// - `region` - where it may draw, in its own coordinates.
/// - `with_kept` - whether its kept pieces and its own bitmap get targets
///   too; false while `BeginUpdate` narrows it to the damage.
///
/// RESULT:
/// False without memory, with the old list still in place.
pub fn install(lb: *LayersBase, layer: *Layer, region: *graphics.Region, with_kept: bool) bool {
    const gb = lb.graphics_base;
    const sys = lb.sys_base;
    const count = gb.RegionRectangles(region, null, 0);

    var list: ?*graphics.ClipTarget = null;
    var tail: ?*graphics.ClipTarget = null;
    if (count != 0) {
        // Room for the rectangles, from the same pool as the targets: the
        // count is not known until it is asked for, and a fixed buffer
        // would be a limit on how broken up a layer may be.
        const bytes = count * @sizeOf(Rect);
        const mem = sys.AllocPooled(layer.info.pool, bytes) orelse return false;
        defer sys.FreePooled(layer.info.pool, mem, bytes);
        const rects: [*]Rect = @ptrCast(@alignCast(mem));
        _ = gb.RegionRectangles(region, rects, count);

        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const t = info_mod.newTarget(sys, layer.info) orelse {
                info_mod.freeTargets(sys, layer.info, list);
                return false;
            };
            const ox, const oy = super.origin(layer);
            t.* = .{
                .rect = rects[i],
                .surface = layer.info.surface,
                .bitmap = layer.info.bitmap,
                // Where the layer sits on the display, which is what lets
                // its program draw at (0,0) and mean its own corner - and
                // where its own bitmap is showing, when it has one.
                .dx = ox,
                .dy = oy,
            };
            // Kept in the order they came out in, which is the order the
            // rectangles lie in - what a blit moving pixels over their own
            // surface needs to read before it writes.
            if (tail) |last| last.next = t else list = t;
            tail = t;
        }
    }

    // What the layer keeps while it is covered draws just the same, into
    // a surface of its own instead of on to the display - which is the
    // whole of LAYERSMART as far as a drawing call is concerned.
    // A layer with a bitmap of its own draws into it everywhere it cannot
    // be seen - which includes the whole of the bitmap that the window is
    // not showing.
    if (with_kept) {
        if (layer.super) |bm| {
            const rest = gb.NewRegion() orelse return false;
            defer gb.DisposeRegion(rest);
            const whole = super.extent(layer);
            if (!gb.OrRectRegion(rest, &whole) or !gb.SubRegionRegion(region, rest)) return false;
            const n = gb.RegionRectangles(rest, null, 0);
            if (n != 0) {
                const room = n * @sizeOf(Rect);
                const mem = sys.AllocPooled(layer.info.pool, room) orelse return false;
                defer sys.FreePooled(layer.info.pool, mem, room);
                const rects: [*]Rect = @ptrCast(@alignCast(mem));
                _ = gb.RegionRectangles(rest, rects, n);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    const t = info_mod.newTarget(sys, layer.info) orelse {
                        info_mod.freeTargets(sys, layer.info, list);
                        return false;
                    };
                    t.* = .{ .rect = rects[i], .surface = bm, .bitmap = null, .dx = 0, .dy = 0 };
                    t.next = list;
                    list = t;
                    if (t.next == null) tail = t;
                }
            }
        }
        var k = layer.kept;
        while (k) |piece| : (k = piece.next) {
            const t = info_mod.newTarget(sys, layer.info) orelse {
                info_mod.freeTargets(sys, layer.info, list);
                return false;
            };
            t.* = .{
                .rect = piece.area,
                .surface = piece.surface,
                .bitmap = null,
                .dx = -piece.area.min_x,
                .dy = -piece.area.min_y,
            };
            // In among the others rather than after them: the order is by
            // where the rectangles lie, and a caller reading it expects
            // that of the whole list.
            var before: ?*graphics.ClipTarget = null;
            var at = list;
            while (at) |other| : (at = other.next) {
                if (t.rect.min_y < other.rect.min_y or
                    (t.rect.min_y == other.rect.min_y and t.rect.min_x < other.rect.min_x)) break;
                before = other;
            }
            if (before) |b| {
                t.next = b.next;
                b.next = t;
            } else {
                t.next = list;
                list = t;
            }
            if (t.next == null) tail = t;
        }
    }

    // A layer that can write nowhere - covered all over, or off the display
    // - still needs a list: to graphics.library no list at all means no
    // clipping, and its RastPort would draw straight on to the display at
    // the display's corner. One target with nothing in it clips everything.
    if (list == null) {
        const t = info_mod.newTarget(sys, layer.info) orelse return false;
        t.* = .{ .rect = .{}, .surface = layer.info.surface, .bitmap = layer.info.bitmap };
        list = t;
    }

    info_mod.freeTargets(sys, layer.info, layer.targets);
    layer.targets = list;
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_ClipTargets, .data = @intFromPtr(list) },
        .{},
    };
    gb.SetRPAttrs(layer.rp, &tags);
    return true;
}

/// Work out a layer's targets again from what it can see.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer.
///
/// RESULT:
/// False without memory.
pub fn rebuild(lb: *LayersBase, layer: *Layer) bool {
    const gb = lb.graphics_base;
    const region = inLayerSpace(lb, layer, null) orelse return false;
    defer gb.DisposeRegion(region);
    return install(lb, layer, region, true);
}

/// Work out every layer's visible area again, and tell each RastPort.
///
/// Called after anything that changes what covers what: a layer made,
/// deleted, or moved in the order. A layer that is uncovered by the change
/// has the uncovered part added to its damage, since with the simple
/// refresh those pixels were not kept anywhere and only its program can
/// put them back.
///
/// **Two passes, and the order between them is the point.** The first
/// works out what each layer can see now and has every layer that keeps
/// its pixels put away what it has just lost - read off the display, which
/// at that moment still shows every layer as it was. Only the second pass
/// puts anything on the display: kept pixels back where a layer is
/// uncovered, and a simple layer's newly visible part painted. Done in one
/// pass, front to back, a layer in front painted or put back its pixels
/// before a smart layer behind it had saved what it was losing there, and
/// the smart layer kept the other layer's picture.
///
/// INPUTS:
/// - `lb` - the library.
/// - `info` - the display.
///
/// RESULT:
/// False if any part of it ran out of memory.
pub fn retile(lb: *LayersBase, info: *LayerInfo) bool {
    const gb = lb.graphics_base;

    // What the layers in front have claimed, in the display's coordinates.
    const covered = gb.NewRegion() orelse return false;
    defer gb.DisposeRegion(covered);

    var ok = true;
    var it = info.layers.iterator();
    while (it.next()) |node| {
        const layer: *Layer = @fieldParentPtr("node", node);
        const seen = gb.NewRegion() orelse {
            ok = false;
            continue;
        };
        layer.next_visible = seen;
        // Cut to the display first: a layer may hang off the edge, and
        // what is off it is not somewhere its pixels may go.
        const on_screen = Rect.intersect(layer.bounds, info.bounds);
        if (!gb.OrRectRegion(seen, &on_screen) or !gb.SubRegionRegion(covered, seen)) ok = false;
        if (!gb.OrRectRegion(covered, &layer.bounds)) ok = false;

        if (layer.flags & layers.LAYERSUPER != 0) {
            // Its own bitmap is its keeping: what has just been covered
            // goes into it now; what has just been uncovered comes back in
            // the second pass.
            if (!super.saveCovered(lb, layer, seen)) ok = false;
        } else if (layer.flags & layers.LAYERSMART != 0) {
            if (!smart.keepCovered(lb, layer, seen)) ok = false;
        }
    }

    it = info.layers.iterator();
    while (it.next()) |node| {
        const layer: *Layer = @fieldParentPtr("node", node);
        const seen = layer.next_visible orelse continue;
        layer.next_visible = null;

        var newly: ?*graphics.Region = null;
        if (layer.flags & layers.LAYERSUPER != 0) {
            if (!super.bringBack(lb, layer, seen)) ok = false;
        } else if (layer.flags & layers.LAYERSMART != 0) {
            // It keeps what is covered and gets it back when it is
            // uncovered, so it is never owed a redraw.
            smart.putBack(lb, layer, seen);
        } else if (info_mod.copyRegion(gb, seen)) |fresh| {
            // Anything it can see now that it could not see before has to
            // be drawn again: nothing kept those pixels.
            if (gb.SubRegionRegion(layer.visible, fresh) and !info_mod.isEmpty(gb, fresh)) {
                gb.OffsetRegion(fresh, -layer.bounds.min_x, -layer.bounds.min_y);
                if (gb.OrRegionRegion(fresh, layer.damage)) {
                    layer.flags |= layers.LAYERREFRESH;
                    // Uncovered and holding whatever was behind it. It is
                    // painted now rather than left showing that until the
                    // program answers the refresh.
                    newly = fresh;
                }
            }
            if (newly == null) gb.DisposeRegion(fresh);
        } else ok = false;

        gb.DisposeRegion(layer.visible);
        layer.visible = seen;

        if (!rebuild(lb, layer)) ok = false;
        // After the targets are in place, so that the paint goes where the
        // layer's pixels go.
        if (newly) |area| {
            backfill.fillRegion(lb, layer, area);
            gb.DisposeRegion(area);
        }
    }
    return ok;
}
