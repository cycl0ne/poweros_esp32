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
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
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
