// SPDX-License-Identifier: MPL-2.0
//! NewLayerInfoTagList: every layer of one display, made the way the tags
//! say - its size and buffer, the lock over its list of layers, the pool
//! their clip targets come from, and whether they are composed.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;
const exec = sdk.exec;
const Rect = graphics.Rect;
const TagItem = sdk.utility.TagItem;

const _layerinfo = @import("_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const LayersBase = @import("../layers.zig").LayersBase;
const compose = @import("../compose/_compose.zig");

/// Makes the LayerInfo of one display, with no layers on it yet, the way
/// the tags say.
///
/// SYNOPSIS:
/// ```zig
/// fn NewLayerInfoTagList(lb: *LayersBase, rp: *graphics.RastPort, tags: ?[*]const TagItem) ?*LayerInfo
/// ```
///
/// SINCE: 0.6. LVO -124.
///
/// INPUTS:
/// - `rp` - the RastPort the display is drawn on, as `CreateRastPortTagList`
///   answers it with no tags. It says how big the display is and where its
///   pixels are. It is read, not taken over.
/// - `tags` - `LATAG_Compose`, or null for none.
///
/// RESULT:
/// The LayerInfo, or null: no memory, or nothing behind `rp` to draw on -
/// which is what a machine with no display gives.
///
/// BEHAVIOR:
/// Everything about the display comes out of the RastPort, so the library
/// never reaches past graphics.library to ask what the machine has. The
/// LayerInfo keeps a RastPort of its own on the same buffer, for putting a
/// covered piece of a layer back, and a memory pool for the clip targets a
/// retile makes by the hundred.
///
/// With `LATAG_Compose` each layer made in it draws into a buffer of its
/// own, the whole of the layer, and what of it can be seen is copied on
/// to the display as it is drawn and as the layers move. That needs a
/// display that is a board's buffer, so that the layers' buffers can be
/// the board's too and its engine draws in them; on plain memory, and on
/// a machine the composing is not built for (the 32-bit ones), the tag is
/// passed over and the layers share the display's buffer.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It allocates.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller owns the LayerInfo until `DisposeLayerInfo`, which also takes
/// away every layer still in it. `rp` and the tags stay the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NewLayerInfo`, `DisposeLayerInfo`, `CreateLayerTagList`
///
/// EXAMPLES:
/// ```zig
/// const composed = [_]TagItem{ .{ .tag = layers.LATAG_Compose, .data = 1 }, .{} };
/// const info = lb.NewLayerInfoTagList(screen_rp, &composed) orelse return error.NoDisplay;
/// defer lb.DisposeLayerInfo(info);
/// ```
pub fn NewLayerInfoTagList(lb: *LayersBase, rp: *graphics.RastPort, tags: ?[*]const TagItem) ?*LayerInfo {
    const sys = lb.sys_base;
    const gb = lb.graphics_base;
    // Everything about the display comes out of the RastPort it is drawn
    // on, so this library never has to reach past graphics.library to ask
    // rtg what the machine has.
    var bounds: Rect = .{};
    var surface: usize = 0;
    var bitmap: usize = 0;
    const ask = [_]TagItem{
        .{ .tag = graphics.RPTAG_Bounds, .data = @intFromPtr(&bounds) },
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_BitMap, .data = @intFromPtr(&bitmap) },
        .{},
    };
    gb.GetRPAttrs(rp, &ask);
    if (bounds.isEmpty() or surface == 0) return null;

    const mem = sys.AllocVec(@sizeOf(LayerInfo), exec.MEMF_CLEAR) orelse return null;
    const info: *LayerInfo = @ptrCast(@alignCast(mem));
    info.* = .{
        .bounds = bounds,
        .surface = @ptrFromInt(surface),
        .bitmap = if (bitmap == 0) null else @ptrFromInt(bitmap),
        .lb = lb,
    };
    // Composed only where the layers' buffers can be the board's.
    info.compose = compose.built and lb.utility_base.GetTagData(layers.LATAG_Compose, 0, tags) != 0 and
        compose.boardOf(info) != null;
    sys.NewList(&info.layers);
    sys.NewList(&info.locks);
    sys.InitSemaphore(&info.lock);
    // A RastPort of this library's own on the same buffer, for putting a
    // covered piece back where it came from.
    var own = [_]TagItem{
        .{ .tag = if (bitmap == 0) graphics.RPTAG_Surface else graphics.RPTAG_BitMap, .data = if (bitmap == 0) surface else bitmap },
        .{},
    };
    info.display_rp = gb.CreateRastPortTagList(&own);
    // A clip target is a few words and a retile makes one per piece of
    // every layer, so they come from a pool rather than one at a time -
    // and DisposeLayerInfo gives the lot back in a single call.
    info.pool = sys.CreatePool(exec.MEMF_ANY, target_puddle, 0) orelse {
        if (info.display_rp) |display_rp| gb.FreeRastPort(display_rp);
        sys.FreeVec(mem);
        return null;
    };
    return info;
}

/// How much the target pool takes at a time. A `ClipTarget` is 28 bytes
/// here, so this is room for about a hundred and forty - a screen's worth
/// of windows broken into pieces, and a page of memory for a machine that
/// opens one window.
const target_puddle = 4096;
