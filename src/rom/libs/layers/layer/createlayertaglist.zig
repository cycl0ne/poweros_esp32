// SPDX-License-Identifier: MPL-2.0
//! CreateLayerTagList: a new layer, with a RastPort of its own whose
//! coordinates start at the layer's corner.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;
const exec = sdk.exec;
const rtg = sdk.rtg;
const Rect = graphics.Rect;
const TagItem = sdk.utility.TagItem;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const _layer = @import("_layer.zig");
const tile = @import("../tile/_tile.zig");
const backfill = @import("../backfill/_backfill.zig");
const super = @import("../super/_super.zig");
const _locks = @import("../locks/_locks.zig");
const LayersBase = @import("../layers.zig").LayersBase;

/// Makes a new layer on a display.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateLayerTagList(lb: *LayersBase, info: *LayerInfo, tags: ?[*]const TagItem) ?*Layer
/// ```
///
/// SINCE: 0.1. LVO -28.
///
/// INPUTS:
/// - `info` - the display it belongs to.
/// - `tags` - the `LATAG_` options:
///   - `LATAG_Bounds` - required: a `*const Rect` in the display's
///     coordinates, with something in it.
///   - `LATAG_Refresh` - `LAYERSIMPLE` (the default), `LAYERSMART` or
///     `LAYERSUPER`.
///   - `LATAG_SuperBitMap` - for `LAYERSUPER`: the `*Surface` it draws
///     into, at least as big as the layer.
///   - `LATAG_Behind` - non-zero puts it behind the ordinary layers instead
///     of in front.
///   - `LATAG_Backdrop` - non-zero keeps it behind every ordinary layer.
///   - `LATAG_BackFill` - what paints its empty parts: 0 for its background
///     pen, `LAYERS_NOBACKFILL` for nothing, or a `*Hook`.
///   - `LATAG_ErrorPtr` - an `*i32` that gets the reason if it fails.
///
/// RESULT:
/// The layer, or null. `LATAG_ErrorPtr` then holds why: `LERR_BAD_BOUNDS`
/// for no rectangle or an empty one, `LERR_NO_SUPERBITMAP` for a
/// `LAYERSUPER` layer without a bitmap big enough, `LERR_NO_RASTPORT`, or
/// `LERR_NO_MEMORY`.
///
/// BEHAVIOR:
/// The layer gets a RastPort of its own whose coordinates start at the
/// layer's corner, so its program draws at `(0,0)` and means the layer's
/// top-left. Every layer's visible area is worked out again, and a layer
/// this one now covers loses those pixels. The new layer is painted with
/// its backfill before anyone can see it, since what is on the display
/// there belongs to whoever had it before; coming into view is not damage.
///
/// The refresh modes differ in what happens to a covered piece:
/// `LAYERSIMPLE` loses it and is owed it back as damage, `LAYERSMART`
/// keeps it in a surface of its own and puts it back, and `LAYERSUPER`
/// keeps it in the program's own bitmap.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the display's layers.
/// - Interrupts: no. It may wait, and it allocates.
/// - Forbid: must not be held: waiting for the locks would break it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The layer and its RastPort are the library's; `DeleteLayer` gives them
/// back, and the caller must not free the RastPort itself. A `LAYERSUPER`
/// bitmap stays the caller's, and must outlive the layer.
///
/// NOTES:
/// A layer made while every layer of the display is held with `LockLayers`
/// is held as well, so that the release gives back what it took.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DeleteLayer`, `GetLayerAttrs`, `NewLayerInfo`
///
/// EXAMPLES:
/// ```zig
/// const where = graphics.Rect{ .min_x = 40, .min_y = 30, .max_x = 240, .max_y = 150 };
/// var err: i32 = 0;
/// const tags = [_]TagItem{
///     .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&where) },
///     .{ .tag = layers.LATAG_ErrorPtr, .data = @intFromPtr(&err) },
///     .{},
/// };
/// const layer = lb.CreateLayerTagList(info, &tags) orelse return error.NoLayer;
/// ```
pub fn CreateLayerTagList(lb: *LayersBase, info: *LayerInfo, tags: ?[*]const TagItem) ?*Layer {
    _locks.holdAll(lb, info);
    defer _locks.releaseAll(lb, info);
    const tag_list = tags;
    const sys = lb.sys_base;
    const ub = lb.utility_base;
    const gb = lb.graphics_base;

    const where = ub.GetTagData(layers.LATAG_Bounds, 0, tag_list);
    if (where == 0) {
        report(lb, tag_list, layers.LERR_BAD_BOUNDS);
        return null;
    }
    const bounds = @as(*const Rect, @ptrFromInt(where)).*;
    if (bounds.isEmpty()) {
        report(lb, tag_list, layers.LERR_BAD_BOUNDS);
        return null;
    }

    var flags: u32 = @truncate(ub.GetTagData(layers.LATAG_Refresh, layers.LAYERSIMPLE, tag_list));
    if (ub.GetTagData(layers.LATAG_Backdrop, 0, tag_list) != 0) flags |= layers.LAYERBACKDROP;
    // A layer of its own bitmap needs one, and it has to be at least as
    // big as the layer or the window would show what is not there.
    const sb: ?*rtg.Surface = @ptrFromInt(ub.GetTagData(layers.LATAG_SuperBitMap, 0, tag_list));
    if (flags & layers.LAYERSUPER != 0) {
        const bm = sb orelse {
            report(lb, tag_list, layers.LERR_NO_SUPERBITMAP);
            return null;
        };
        if (bm.width < bounds.width() or bm.height < bounds.height()) {
            report(lb, tag_list, layers.LERR_NO_SUPERBITMAP);
            return null;
        }
    }

    const mem = sys.AllocVec(@sizeOf(Layer), exec.MEMF_CLEAR) orelse {
        report(lb, tag_list, layers.LERR_NO_MEMORY);
        return null;
    };
    const layer: *Layer = @ptrCast(@alignCast(mem));

    // The RastPort draws on the display's buffer, and its own coordinates
    // start at the layer's corner - so its clip is the layer's size, not
    // the layer's place. A layer with a bitmap of its own draws in that
    // bitmap's coordinates and may reach all of it.
    const own = if (flags & layers.LAYERSUPER != 0 and sb != null)
        Rect{ .max_x = @intCast(sb.?.width), .max_y = @intCast(sb.?.height) }
    else
        Rect{ .max_x = bounds.width(), .max_y = bounds.height() };
    var rp_tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&own) },
        .{ .tag = if (info.bitmap != null) graphics.RPTAG_BitMap else graphics.RPTAG_Surface, .data = if (info.bitmap) |bm| @intFromPtr(bm) else @intFromPtr(info.surface) },
        // The RastPort carries how the layer's empty parts are painted, so
        // that anything given the RastPort alone paints them the same way.
        .{ .tag = graphics.RPTAG_BackFill, .data = ub.GetTagData(layers.LATAG_BackFill, 0, tag_list) },
        .{},
    };
    const rp = gb.CreateRastPortTagList(&rp_tags) orelse {
        sys.FreeVec(mem);
        report(lb, tag_list, layers.LERR_NO_RASTPORT);
        return null;
    };
    const seen = gb.NewRegion() orelse {
        gb.FreeRastPort(rp);
        sys.FreeVec(mem);
        report(lb, tag_list, layers.LERR_NO_MEMORY);
        return null;
    };
    const owed = gb.NewRegion() orelse {
        gb.DisposeRegion(seen);
        gb.FreeRastPort(rp);
        sys.FreeVec(mem);
        report(lb, tag_list, layers.LERR_NO_MEMORY);
        return null;
    };

    layer.* = .{
        .info = info,
        .bounds = bounds,
        .flags = flags,
        .backfill = ub.GetTagData(layers.LATAG_BackFill, 0, tag_list),
        .super = if (flags & layers.LAYERSUPER != 0) sb else null,
        .rp = rp,
        .visible = seen,
        .damage = owed,
    };
    sys.InitSemaphore(&layer.lock);
    // Every layer's lock is also on the LayerInfo's list, so LockLayers is
    // one ObtainSemaphoreList rather than a walk that two callers going
    // opposite ways would deadlock on.
    sys.AddTail(&info.locks, &layer.lock.link);
    // A layer made while every layer is held **inherits that hold**. The
    // list it has just joined is released as a list, so a semaphore on it
    // that was never obtained is one the release cannot account for - and
    // exec says so, with an alert, which is how this was found.
    var held: u32 = 0;
    while (held < info.locked_all) : (held += 1) sys.ObtainSemaphore(&layer.lock);

    _layer.insert(sys, info, layer, ub.GetTagData(layers.LATAG_Behind, 0, tag_list) != 0);
    if (!tile.retile(lb, info)) layer.last_error = layers.LERR_NO_MEMORY;
    // Nothing has ever been drawn in it, and what is on the display there
    // belongs to whoever had it before, so it is painted before anyone can
    // see it.
    backfill.fill(lb, layer, super.extent(layer));
    // Coming into view is not damage: the whole layer was just made and
    // its program is about to draw it. What the retile put there is for
    // the layers that were already here.
    gb.ClearRegion(layer.damage);
    layer.flags &= ~layers.LAYERREFRESH;
    report(lb, tag_list, layer.last_error);
    return layer;
}

/// Writes an error where the caller asked for it, if it did. The layer that
/// would have carried it does not exist, which is the only reason this does.
///
/// INPUTS:
/// - `lb` - the library, for the tag call.
/// - `tag_list` - the caller's tags, which may hold `LATAG_ErrorPtr`.
/// - `code` - the `LERR_` code.
fn report(lb: *LayersBase, tag_list: ?[*]const TagItem, code: i32) void {
    const where = lb.utility_base.GetTagData(layers.LATAG_ErrorPtr, 0, tag_list);
    if (where != 0) @as(*i32, @ptrFromInt(where)).* = code;
}
