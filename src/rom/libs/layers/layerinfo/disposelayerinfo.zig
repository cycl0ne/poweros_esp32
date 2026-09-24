// SPDX-License-Identifier: MPL-2.0
//! DisposeLayerInfo: throws a LayerInfo away, with every layer still in it
//! and the pool that held their clip targets.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;

const _layerinfo = @import("_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const LayersBase = @import("../layers.zig").LayersBase;

/// Throws a LayerInfo away, and every layer still in it.
///
/// SYNOPSIS:
/// ```zig
/// fn DisposeLayerInfo(lb: *LayersBase, info: ?*LayerInfo) void
/// ```
///
/// SINCE: 0.1. LVO -24.
///
/// INPUTS:
/// - `info` - the LayerInfo. Null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Each layer is taken away with `DeleteLayer`, so no RastPort or region
/// is left behind, and then the pool that held every clip target goes back
/// in one call. Nothing has to have been taken away first.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the display's layers.
/// - Interrupts: no. It may wait, and it frees memory.
/// - Forbid: must not be held: waiting for the locks would break it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The LayerInfo and every layer in it are gone, with their RastPorts.
/// The display's own RastPort, which `NewLayerInfo` was given, stays the
/// caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NewLayerInfo`, `DeleteLayer`
///
/// EXAMPLES:
/// ```zig
/// lb.DisposeLayerInfo(info);
/// ```
pub fn DisposeLayerInfo(lb: *LayersBase, info: ?*LayerInfo) void {
    const layers_lib = lb.iface();
    const layer_info = info orelse return;
    // Every layer still in it goes first, through DeleteLayer, so nothing
    // is left holding a RastPort or a region after the pool behind it is
    // gone.
    while (layer_info.layers.first()) |node| {
        const layer: *Layer = @fieldParentPtr("node", node);
        layers_lib.DeleteLayer(@ptrCast(layer));
    }
    // This library's own RastPort on the display goes with it.
    if (layer_info.display_rp) |rp| lb.graphics_base.FreeRastPort(rp);
    // Every clip target the pool ever held, in one call.
    lb.sys_base.DeletePool(layer_info.pool);
    lb.sys_base.FreeVec(layer_info);
}
