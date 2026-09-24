// SPDX-License-Identifier: MPL-2.0
//! LockLayerInfo: holds the list of layers still - which there are, and in
//! what order.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const LayersBase = @import("../layers.zig").LayersBase;

/// Holds the list of layers still: which there are, and in what order.
///
/// SYNOPSIS:
/// ```zig
/// fn LockLayerInfo(lb: *LayersBase, info: *LayerInfo) void
/// ```
///
/// SINCE: 0.1. LVO -84.
///
/// INPUTS:
/// - `info` - the display's layers.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// What it protects is the order, not any one layer's pixels. Anything
/// walking the layers - `WhichLayer` over several points, say - wants it.
/// It nests.
///
/// CONTEXT:
/// - Waits: yes, while another task holds it.
/// - Interrupts: no. It waits.
/// - Forbid: must not be held: waiting would break it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller holds the list until `UnlockLayerInfo`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UnlockLayerInfo`, `LockLayers`
///
/// EXAMPLES:
/// ```zig
/// lb.LockLayerInfo(info);
/// defer lb.UnlockLayerInfo(info);
/// ```
pub fn LockLayerInfo(lb: *LayersBase, info: *LayerInfo) void {
    lb.sys_base.ObtainSemaphore(&info.lock);
}
