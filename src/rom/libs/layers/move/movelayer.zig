// SPDX-License-Identifier: MPL-2.0
//! MoveLayer: moves a layer, carrying its pixels with it where it can.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;

const Layer = @import("../layerinfo/_layerinfo.zig").Layer;
const LayersBase = @import("../layers.zig").LayersBase;

/// Moves a layer.
///
/// SYNOPSIS:
/// ```zig
/// fn MoveLayer(lb: *LayersBase, layer: *Layer, dx: i32, dy: i32) bool
/// ```
///
/// SINCE: 0.1. LVO -92.
///
/// INPUTS:
/// - `layer` - the layer.
/// - `dx` - how far across, in the display's coordinates.
/// - `dy` - how far down.
///
/// RESULT:
/// True, or false with the reason in the layer: `LERR_BAD_BOUNDS` or
/// `LERR_NO_MEMORY`, as for `MoveSizeLayer`.
///
/// BEHAVIOR:
/// `MoveSizeLayer` with no change of size. A simple layer carries the
/// pixels that stay visible and is owed the rest; a smart layer is owed
/// nothing.
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
/// `MoveSizeLayer`, `SizeLayer`
///
/// EXAMPLES:
/// ```zig
/// _ = lb.MoveLayer(layer, 16, -8);
/// ```
pub fn MoveLayer(lb: *LayersBase, layer: *Layer, dx: i32, dy: i32) bool {
    const layers_lib = lb.iface();
    return layers_lib.MoveSizeLayer(@ptrCast(layer), dx, dy, 0, 0);
}
