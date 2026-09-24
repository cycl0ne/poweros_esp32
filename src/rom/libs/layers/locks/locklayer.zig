// SPDX-License-Identifier: MPL-2.0
//! LockLayer: holds one layer still, so its clipping cannot change under a
//! drawing call.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const LayersBase = @import("../layers.zig").LayersBase;

/// Holds one layer still.
///
/// SYNOPSIS:
/// ```zig
/// fn LockLayer(lb: *LayersBase, layer: *Layer) void
/// ```
///
/// SINCE: 0.1. LVO -68.
///
/// INPUTS:
/// - `layer` - the layer.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Its clipping cannot change while it is held, so a drawing call cannot
/// have the ground move under it. It nests: the same task may take it again
/// and must let it go as often.
///
/// CONTEXT:
/// - Waits: yes, while another task holds it.
/// - Interrupts: no. It waits.
/// - Forbid: must not be held: waiting would break it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller holds the layer until `UnlockLayer`.
///
/// NOTES:
/// **A task drawing into a layer must hold this while it draws.** The calls
/// that rebuild a layer's clipping take it themselves, but the walking of
/// that clipping is done inside graphics.library, which has no idea layers
/// exist - so only the task that decided to draw can take it. Without it, a
/// retile can free the clip list a drawing call is part way through.
///
/// Be brief: anything that would move or resize the layer waits for it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UnlockLayer`, `LockLayers`
///
/// EXAMPLES:
/// ```zig
/// lb.LockLayer(layer);
/// defer lb.UnlockLayer(layer);
/// gb.RectFill(rp, &area);
/// ```
pub fn LockLayer(lb: *LayersBase, layer: *Layer) void {
    lb.sys_base.ObtainSemaphore(&layer.lock);
    // A caller takes this lock because it is about to draw, so what it
    // draws is one piece of work: the rows are gathered and go to the
    // display together at the unlock, rather than one call at a time.
    // Something rubbed out and drawn again is then never shown half
    // done.
    lb.graphics_base.BeginDraw(layer.rp);
}
