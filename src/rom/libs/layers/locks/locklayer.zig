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
/// - Locks: no spinlock may be held: it waits.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller holds the layer until `UnlockLayer`.
///
/// NOTES:
/// Every drawing call through the layer's RastPort holds it by itself for
/// as long as that call draws - the RastPort carries it, as `RPTAG_Lock` -
/// so no retile frees the clipping, nor a size change the buffer, under
/// one call. A task holds it across several calls that belong together:
/// the layer neither moves nor changes size between them, and what they
/// draw goes to the display at once, never half done.
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
