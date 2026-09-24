// SPDX-License-Identifier: MPL-2.0
//! WhichLayer: which layer a point of the display is in, by what each
//! layer can see.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const LayersBase = @import("../layers.zig").LayersBase;

/// Tells which layer a point of the display is in.
///
/// SYNOPSIS:
/// ```zig
/// fn WhichLayer(lb: *LayersBase, info: *LayerInfo, x: i32, y: i32) ?*Layer
/// ```
///
/// SINCE: 0.1. LVO -48.
///
/// INPUTS:
/// - `info` - the display's layers.
/// - `x` - the point's column, in the display's coordinates.
/// - `y` - its row.
///
/// RESULT:
/// The frontmost layer that can be seen at the point, or null if none can.
///
/// BEHAVIOR:
/// Front to back, by what each layer can **see** rather than by what its
/// rectangle covers - so the answer is the layer that would be drawn on
/// there. A point no layer can see is nobody's, which is not the same as
/// the rectangles' answer for a layer hanging off the display.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed, though the list must not change meanwhile:
///   `LockLayerInfo` is how to be sure.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The layer stays the library's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockLayerInfo`
///
/// EXAMPLES:
/// ```zig
/// lb.LockLayerInfo(info);
/// defer lb.UnlockLayerInfo(info);
/// const hit = lb.WhichLayer(info, mouse_x, mouse_y);
/// ```
pub fn WhichLayer(lb: *LayersBase, info: *LayerInfo, x: i32, y: i32) ?*Layer {
    const gb = lb.graphics_base;
    var it = info.layers.iterator();
    while (it.next()) |node| {
        const layer: *Layer = @fieldParentPtr("node", node);
        // What the layer can **see** there, not merely what its rectangle
        // covers. Front to back the two agree about which layer owns a
        // point that some layer owns - but a point no layer can see, off
        // the display or behind one hanging over the edge, is nobody's,
        // and the rectangles would have said otherwise.
        if (gb.PointInRegion(layer.visible, x, y)) return layer;
    }
    return null;
}
