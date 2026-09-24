// SPDX-License-Identifier: MPL-2.0
//! MoveLayerInFrontOf: puts one layer directly in front of another.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const tile = @import("../tile/_tile.zig");
const _locks = @import("../locks/_locks.zig");
const LayersBase = @import("../layers.zig").LayersBase;

/// Puts one layer directly in front of another.
///
/// SYNOPSIS:
/// ```zig
/// fn MoveLayerInFrontOf(lb: *LayersBase, layer: *Layer, other: *Layer) bool
/// ```
///
/// SINCE: 0.1. LVO -44.
///
/// INPUTS:
/// - `layer` - the layer to move.
/// - `other` - the layer it goes in front of. Both are of one LayerInfo.
///
/// RESULT:
/// True, or false with `LERR_NO_MEMORY` in the layer if the tiling could
/// not be worked out. A layer put in front of itself stays and answers
/// true.
///
/// BEHAVIOR:
/// What it now covers is lost to those layers, and what it uncovers is
/// given back to them - as damage for a simple layer, out of its keeping
/// for a smart or super one.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the display's layers.
/// - Interrupts: no. It may wait, and it allocates.
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
/// `UpfrontLayer`, `BehindLayer`
///
/// EXAMPLES:
/// ```zig
/// _ = lb.MoveLayerInFrontOf(dialog, parent);
/// ```
pub fn MoveLayerInFrontOf(lb: *LayersBase, layer: *Layer, other: *Layer) bool {
    _locks.holdAll(lb, layer.info);
    defer _locks.releaseAll(lb, layer.info);
    if (layer == other) return true;
    const info = layer.info;
    lb.sys_base.Remove(&layer.node);
    lb.sys_base.Insert(&info.layers, &layer.node, other.node.pred);
    const ok = tile.retile(lb, info);
    layer.last_error = if (ok) layers.LERR_OK else layers.LERR_NO_MEMORY;
    return ok;
}
