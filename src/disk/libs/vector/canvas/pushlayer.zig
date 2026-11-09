// SPDX-License-Identifier: MIT
//! PushLayer: what is drawn from now on goes onto a layer of its own.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// What is drawn until PopLayer goes onto a layer of its own, put down at the opacity.
///
/// SYNOPSIS:
/// ```zig
/// fn PushLayer(vb: *VectorBase, canvas: *vector.Canvas, opacity: f32) i32
/// ```
///
/// SINCE: 1.1. LVO -92.
///
/// INPUTS:
/// - `canvas` - the canvas.
/// - `opacity` - how much of the layer shows when it is put down, 0 to 1:
///   SVG's `opacity` on a group.
///
/// RESULT:
/// `VECTOR_OK`; `VECTORERR_NOMEM` without the memory for the layer, which
/// is then drawn without one; `VECTORERR_DEPTH` past `MAX_LAYERS` layers
/// one inside another, when the layer is nothing. Whatever it answers,
/// a `PopLayer` goes with it.
///
/// BEHAVIOR:
/// Every fill and stroke from now until the `PopLayer` that goes with
/// it is drawn onto pens of the layer's own, clear and the canvas's
/// size; the pop puts them down on what is under them at `opacity`. So a
/// group's shapes that overlap are seen as one, at the group's opacity,
/// not through each other. Layers go inside one another.
///
/// Without the memory for the layer, the opacity goes into every paint
/// drawn until the pop instead, which is the same where the shapes do
/// not overlap - drawn a little wrong rather than not at all.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The layer is the canvas's, given back by the pop or by
/// `DisposeCanvas`.
///
/// NOTES:
/// A layer is four bytes a pixel of the whole canvas, cleared when
/// pushed: on a small machine, a large canvas's layers are what runs
/// out first.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `PopLayer`, `FillPath`
///
/// EXAMPLES:
/// ```zig
/// _ = vb.PushLayer(canvas, 0.5);
/// _ = vb.FillPath(canvas, body, null, &grey, vector.RULE_NONZERO);
/// _ = vb.StrokePath(canvas, body, null, &black, &outline);
/// vb.PopLayer(canvas);
/// ```
pub fn PushLayer(vb: *VectorBase, canvas: *vector.Canvas, opacity: f32) i32 {
    _ = vb;
    return _base.canvasOf(canvas).pushLayer(opacity);
}
