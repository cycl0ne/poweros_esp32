// SPDX-License-Identifier: MPL-2.0
//! LockLayers: holds every layer of a display still, all at once.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const LayersBase = @import("../layers.zig").LayersBase;

/// Holds every layer of a display still.
///
/// SYNOPSIS:
/// ```zig
/// fn LockLayers(lb: *LayersBase, info: *LayerInfo) void
/// ```
///
/// SINCE: 0.1. LVO -76.
///
/// INPUTS:
/// - `info` - the display's layers.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The list is taken first, then all of the layers at once. Taking them one
/// at a time would let two callers going opposite ways each hold what the
/// other waits for; one call over the whole list cannot. A layer made while
/// they are held is held as well. It nests.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the list or a layer.
/// - Interrupts: no. It waits.
/// - Forbid: must not be held: waiting would break it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller holds the list and every layer until `UnlockLayers`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UnlockLayers`, `LockLayer`, `LockLayerInfo`
///
/// EXAMPLES:
/// ```zig
/// lb.LockLayers(info);
/// defer lb.UnlockLayers(info);
/// ```
pub fn LockLayers(lb: *LayersBase, info: *LayerInfo) void {
    const layers_lib = lb.iface();
    const layer_info = info;
    // The list first, so that nothing joins or leaves while the layers are
    // being taken, and then all of them at once.
    layers_lib.LockLayerInfo(@ptrCast(info));
    layer_info.locked_all += 1;
    lb.sys_base.ObtainSemaphoreList(&layer_info.locks);
    // Everything taken together is one piece of work too. A retile
    // repaints piece by piece, and the display wants the finished
    // arrangement, not every piece of it on the way there. The batch is
    // held on this library's own RastPort, which is on the board's
    // buffer: the layers themselves come and go while this is held, so a
    // batch held on one of them could not be given back.
    if (layer_info.display_rp) |rp| lb.graphics_base.BeginDraw(rp);
}
