// SPDX-License-Identifier: MPL-2.0
//! UnlockLayer: lets a layer go again.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const LayersBase = @import("../layers.zig").LayersBase;

/// Lets a layer go again.
///
/// SYNOPSIS:
/// ```zig
/// fn UnlockLayer(lb: *LayersBase, layer: *Layer) void
/// ```
///
/// SINCE: 0.1. LVO -72.
///
/// INPUTS:
/// - `layer` - a layer the caller holds.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// One `LockLayer` given back; the layer is free when every one has been.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: the task that took it.
///
/// OWNERSHIP:
/// The caller no longer holds it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockLayer`
///
/// EXAMPLES:
/// ```zig
/// lb.UnlockLayer(layer);
/// ```
pub fn UnlockLayer(lb: *LayersBase, layer: *Layer) void {
    // The rows go while the lock is still held, so what reaches the
    // display is the picture this caller finished and not one another
    // has already started changing.
    lb.graphics_base.EndDraw(layer.rp);
    lb.sys_base.ReleaseSemaphore(&layer.lock);
}
