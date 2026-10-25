// SPDX-License-Identifier: MPL-2.0
//! NewLayerInfo: every layer of one display - its size and buffer, the lock
//! over its list of layers, and the pool their clip targets come from.

const sdk = @import("sdk");
const graphics = sdk.graphics;

const _layerinfo = @import("_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const LayersBase = @import("../layers.zig").LayersBase;
const NewLayerInfoTagList = @import("newlayerinfotaglist.zig").NewLayerInfoTagList;

/// Makes the LayerInfo of one display, with no layers on it yet.
///
/// SYNOPSIS:
/// ```zig
/// fn NewLayerInfo(lb: *LayersBase, rp: *graphics.RastPort) ?*LayerInfo
/// ```
///
/// SINCE: 0.1. LVO -20.
///
/// INPUTS:
/// - `rp` - the RastPort the display is drawn on, as `CreateRastPortTagList`
///   answers it with no tags. It says how big the display is and where its
///   pixels are. It is read, not taken over.
///
/// RESULT:
/// The LayerInfo, or null: no memory, or nothing behind `rp` to draw on -
/// which is what a machine with no display gives.
///
/// BEHAVIOR:
/// `NewLayerInfoTagList` with no tags: the layers share the display's
/// buffer.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It allocates.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller owns the LayerInfo until `DisposeLayerInfo`, which also takes
/// away every layer still in it. `rp` stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NewLayerInfoTagList`, `DisposeLayerInfo`, `CreateLayerTagList`
///
/// EXAMPLES:
/// ```zig
/// const info = lb.NewLayerInfo(screen_rp) orelse return error.NoDisplay;
/// defer lb.DisposeLayerInfo(info);
/// ```
pub fn NewLayerInfo(lb: *LayersBase, rp: *graphics.RastPort) ?*LayerInfo {
    return NewLayerInfoTagList(lb, rp, null);
}
