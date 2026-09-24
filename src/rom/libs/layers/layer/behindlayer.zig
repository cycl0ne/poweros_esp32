// SPDX-License-Identifier: MPL-2.0
//! BehindLayer: puts a layer behind every other ordinary one, in front of
//! the backdrops.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const _layer = @import("_layer.zig");
const _locks = @import("../locks/_locks.zig");
const LayersBase = @import("../layers.zig").LayersBase;

/// Puts a layer behind every other ordinary one.
///
/// SYNOPSIS:
/// ```zig
/// fn BehindLayer(lb: *LayersBase, layer: *Layer) bool
/// ```
///
/// SINCE: 0.1. LVO -40.
///
/// INPUTS:
/// - `layer` - the layer.
///
/// RESULT:
/// True, or false with `LERR_NO_MEMORY` in the layer if the tiling could
/// not be worked out.
///
/// BEHAVIOR:
/// Behind the ordinary layers, but still in front of the backdrop ones -
/// which is what makes them backdrops. What it now covers is lost to those layers, and what it uncovers is
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
/// `UpfrontLayer`, `MoveLayerInFrontOf`
///
/// EXAMPLES:
/// ```zig
/// _ = lb.BehindLayer(layer);
/// ```
pub fn BehindLayer(lb: *LayersBase, layer: *Layer) bool {
    _locks.holdAll(lb, layer.info);
    defer _locks.releaseAll(lb, layer.info);
    return _layer.reorder(lb, layer, .back);
}
