// SPDX-License-Identifier: MPL-2.0
//! InstallLayerHook: changes what paints a part of a layer that has
//! nothing in it yet.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;
const TagItem = sdk.utility.TagItem;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const _locks = @import("../locks/_locks.zig");
const compose = @import("../compose/_compose.zig");
const LayersBase = @import("../layers.zig").LayersBase;

/// Changes what paints a part of a layer that has nothing in it yet.
///
/// SYNOPSIS:
/// ```zig
/// fn InstallLayerHook(lb: *LayersBase, layer: *Layer, hook: usize) usize
/// ```
///
/// SINCE: 0.1. LVO -108.
///
/// INPUTS:
/// - `layer` - the layer.
/// - `hook` - a `*Hook`, or 0 for the layer's own background pen, or
///   `LAYERS_NOBACKFILL` for nothing at all: what `LATAG_BackFill` takes.
///
/// RESULT:
/// What was there before, to be put back or thrown away.
///
/// BEHAVIOR:
/// It paints nothing by itself; it says what the next painting will use - a
/// layer made bigger, uncovered, or created after this. The layer's
/// RastPort carries it too, so anything handed the RastPort alone paints
/// the ground the same way.
///
/// A layer with no buffer (`LATAG_NoBuffer`) is nothing but what its
/// backfill paints, so it is shown again at once, painted by the new one -
/// how a screen's ground takes new pens, with the same hook installed
/// again. It cannot show nothing: `LAYERS_NOBACKFILL` is its background
/// pen instead, and 0 is what is given back for it after.
///
/// CONTEXT:
/// - Waits: for a layer with no buffer, while another task holds any of
///   the display's layers; otherwise no.
/// - Interrupts: no.
/// - Locks: none needed; for a layer with no buffer, every layer of the
///   display, taken here.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The hook stays the caller's and must outlive its use by the layer.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DoHookClipRects`, `CreateLayerTagList`
///
/// EXAMPLES:
/// ```zig
/// const old = lb.InstallLayerHook(layer, @intFromPtr(&pattern_hook));
/// ```
pub fn InstallLayerHook(lb: *LayersBase, layer: *Layer, hook: usize) usize {
    if (compose.bare(layer)) {
        const info = layer.info;
        _locks.holdAll(lb, info);
        defer _locks.releaseAll(lb, info);
        const was = install(lb, layer, if (hook == layers.LAYERS_NOBACKFILL) 0 else hook);
        compose.show(lb, info, layer.bounds);
        return was;
    }
    return install(lb, layer, hook);
}

fn install(lb: *LayersBase, layer: *Layer, hook: usize) usize {
    const was = layer.backfill;
    layer.backfill = hook;
    // The RastPort carries it too, so that anything handed the RastPort
    // alone - an image being erased inside a window - paints the ground the
    // same way this library would. The two are set together and never drift.
    const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_BackFill, .data = hook }, .{} };
    lb.graphics_base.SetRPAttrs(layer.rp, &tags);
    layer.last_error = layers.LERR_OK;
    return was;
}
