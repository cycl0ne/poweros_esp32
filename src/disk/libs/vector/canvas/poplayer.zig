// SPDX-License-Identifier: MIT
//! PopLayer: the last layer pushed put down.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// The last layer pushed put down on what is under it.
///
/// SYNOPSIS:
/// ```zig
/// fn PopLayer(vb: *VectorBase, canvas: *vector.Canvas) void
/// ```
///
/// SINCE: 1.1. LVO -96.
///
/// INPUTS:
/// - `canvas` - the canvas.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// What was drawn on the layer goes down on what is under it - the layer
/// it is inside, or the pens - at the layer's opacity, each pixel over
/// what is there as a paint goes; and the layer is given back. A layer
/// that had no memory, or was past the most, is only ended. With no
/// layer pushed it does nothing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pens under the layer are written.
///
/// NOTES:
/// Pens set with `SetCanvasPens` while a layer is pushed are the ones
/// it goes down on.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `PushLayer`
///
/// EXAMPLES:
/// ```zig
/// vb.PopLayer(canvas);
/// ```
pub fn PopLayer(vb: *VectorBase, canvas: *vector.Canvas) void {
    _ = vb;
    _base.canvasOf(canvas).popLayer();
}
