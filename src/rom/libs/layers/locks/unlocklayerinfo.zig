// SPDX-License-Identifier: MPL-2.0
//! UnlockLayerInfo: lets the list of layers go again.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const LayersBase = @import("../layers.zig").LayersBase;

/// Lets the list of layers go again.
///
/// SYNOPSIS:
/// ```zig
/// fn UnlockLayerInfo(lb: *LayersBase, info: *LayerInfo) void
/// ```
///
/// SINCE: 0.1. LVO -88.
///
/// INPUTS:
/// - `info` - the display's layers, held with `LockLayerInfo`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// One `LockLayerInfo` given back.
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
/// `LockLayerInfo`
///
/// EXAMPLES:
/// ```zig
/// lb.UnlockLayerInfo(info);
/// ```
pub fn UnlockLayerInfo(lb: *LayersBase, info: *LayerInfo) void {
    lb.sys_base.ReleaseSemaphore(&info.lock);
}
