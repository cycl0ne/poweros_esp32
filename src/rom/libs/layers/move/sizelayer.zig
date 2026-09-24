// SPDX-License-Identifier: MPL-2.0
//! SizeLayer: changes a layer's size, its top-left staying where it is.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;

const Layer = @import("../layerinfo/_layerinfo.zig").Layer;
const LayersBase = @import("../layers.zig").LayersBase;

/// Changes a layer's size, its top-left staying where it is.
///
/// SYNOPSIS:
/// ```zig
/// fn SizeLayer(lb: *LayersBase, layer: *Layer, dw: i32, dh: i32) bool
/// ```
///
/// SINCE: 0.1. LVO -96.
///
/// INPUTS:
/// - `layer` - the layer.
/// - `dw` - how much wider; negative makes it narrower.
/// - `dh` - how much taller; negative makes it shorter.
///
/// RESULT:
/// True, or false with the reason in the layer: `LERR_BAD_BOUNDS` or
/// `LERR_NO_MEMORY`, as for `MoveSizeLayer`.
///
/// BEHAVIOR:
/// `MoveSizeLayer` without moving. What is still inside the layer is kept;
/// what it gains has nothing in it, so a simple layer is owed it as damage
/// and a smart one has it painted.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the display's layers.
/// - Interrupts: no. It may wait, it allocates, and it draws.
/// - Forbid: must not be held: waiting for the locks would break it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated that outlives the call.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MoveSizeLayer`, `MoveLayer`
///
/// EXAMPLES:
/// ```zig
/// _ = lb.SizeLayer(layer, 100, 50);
/// ```
pub fn SizeLayer(lb: *LayersBase, layer: *Layer, dw: i32, dh: i32) bool {
    const layers_lib = lb.iface();
    return layers_lib.MoveSizeLayer(@ptrCast(layer), 0, 0, dw, dh);
}
