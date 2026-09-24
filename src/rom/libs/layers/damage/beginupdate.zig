// SPDX-License-Identifier: MPL-2.0
//! BeginUpdate: narrows a layer to its damage - what was uncovered and not
//! drawn again - so its program can draw all of itself and touch only what
//! it owes. With the simple refresh, covered pixels are kept nowhere, which
//! is why a layer can owe a redraw at all.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const tile = @import("../tile/_tile.zig");
const _locks = @import("../locks/_locks.zig");
const LayersBase = @import("../layers.zig").LayersBase;

/// Narrows a layer to what it owes a redraw.
///
/// SYNOPSIS:
/// ```zig
/// fn BeginUpdate(lb: *LayersBase, layer: *Layer) bool
/// ```
///
/// SINCE: 0.1. LVO -60.
///
/// INPUTS:
/// - `layer` - the layer.
///
/// RESULT:
/// True if there was damage and the layer is now narrowed to it. False if
/// there was none, if an update was already on, or with `LERR_NO_MEMORY` in
/// the layer if there was no memory.
///
/// BEHAVIOR:
/// Between this and `EndUpdate` a program can draw all of itself and touch
/// only the parts that were uncovered: the rest of the layer is clipped
/// away. The whole clip list is put aside rather than freed, since it is
/// what the layer goes back to and working it out again could fail for want
/// of memory just when there is none.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the layer.
/// - Interrupts: no. It may wait, and it allocates.
/// - Forbid: must not be held: waiting for the lock would break it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing the caller has to free.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `EndUpdate`, `GetLayerAttrs`
///
/// EXAMPLES:
/// ```zig
/// if (lb.BeginUpdate(layer)) {
///     drawWholeWindow(rp); // only the damage lands
///     lb.EndUpdate(layer, true);
/// }
/// ```
pub fn BeginUpdate(lb: *LayersBase, layer: *Layer) bool {
    _locks.holdOne(lb, layer);
    defer _locks.releaseOne(lb, layer);
    const gb = lb.graphics_base;
    layer.last_error = layers.LERR_OK;
    if (layer.flags & layers.LAYERUPDATING != 0) return false;
    if (_layerinfo.isEmpty(gb, layer.damage)) return false;

    const narrowed = tile.inLayerSpace(lb, layer, layer.damage) orelse {
        layer.last_error = layers.LERR_NO_MEMORY;
        return false;
    };
    defer gb.DisposeRegion(narrowed);

    // Put the whole list aside rather than let it be freed: it is what the
    // layer goes back to, and working it out again could fail for want of
    // memory just when there is none.
    layer.saved_targets = layer.targets;
    layer.targets = null;
    if (!tile.install(lb, layer, narrowed, false)) {
        layer.targets = layer.saved_targets;
        layer.saved_targets = null;
        layer.last_error = layers.LERR_NO_MEMORY;
        return false;
    }
    layer.flags |= layers.LAYERUPDATING;
    return true;
}
