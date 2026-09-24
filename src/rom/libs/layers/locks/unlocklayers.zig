// SPDX-License-Identifier: MPL-2.0
//! UnlockLayers: lets every layer of a display go again.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const LayersBase = @import("../layers.zig").LayersBase;

/// Lets every layer of a display go again.
///
/// SYNOPSIS:
/// ```zig
/// fn UnlockLayers(lb: *LayersBase, info: *LayerInfo) void
/// ```
///
/// SINCE: 0.1. LVO -80.
///
/// INPUTS:
/// - `info` - the display's layers, held with `LockLayers`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The layers first, then the list: the reverse of `LockLayers`.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: the task that took them.
///
/// OWNERSHIP:
/// The caller no longer holds them.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockLayers`
///
/// EXAMPLES:
/// ```zig
/// lb.UnlockLayers(info);
/// ```
pub fn UnlockLayers(lb: *LayersBase, info: *LayerInfo) void {
    const layers_lib = lb.iface();
    const layer_info = info;
    if (layer_info.display_rp) |rp| lb.graphics_base.EndDraw(rp);
    lb.sys_base.ReleaseSemaphoreList(&layer_info.locks);
    if (layer_info.locked_all != 0) layer_info.locked_all -= 1;
    layers_lib.UnlockLayerInfo(@ptrCast(info));
}
