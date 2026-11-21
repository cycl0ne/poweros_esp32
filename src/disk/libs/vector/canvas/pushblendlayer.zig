// SPDX-License-Identifier: MIT
//! PushBlendLayer: a layer put down in a blend mode.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// What is drawn until PopLayer goes onto a layer of its own, put down at the opacity in a blend mode.
///
/// SYNOPSIS:
/// ```zig
/// fn PushBlendLayer(vb: *VectorBase, canvas: *vector.Canvas, opacity: f32, mode: u32) i32
/// ```
///
/// SINCE: 1.5. LVO -124.
///
/// INPUTS:
/// - `canvas` - the canvas.
/// - `opacity` - how much of the layer shows when it is put down, 0 to 1.
/// - `mode` - how its colours go onto those under it, `BLEND_*`: CSS's
///   `mix-blend-mode`, or one of Porter and Duff's operators. A number
///   past the last is `BLEND_NORMAL`.
///
/// RESULT:
/// As `PushLayer`'s: `VECTOR_OK`; `VECTORERR_NOMEM` without the memory
/// for the layer; `VECTORERR_DEPTH` past `MAX_LAYERS`. A `PopLayer` goes
/// with it whatever it answers.
///
/// BEHAVIOR:
/// `PushLayer`, and the pop that goes with it puts the layer down in
/// `mode`: where the layer and what is under it are both, the two
/// colours are mixed by the mode - multiplied, screened, the darker of
/// the two, the layer's hue with the luminosity under it, and the rest
/// as CSS has them - and that is laid over what is under at the layer's
/// coverage and opacity. Where only one of them is, it shows as it is.
/// `BLEND_PLUS_LIGHTER` adds the two instead, colours and coverage, held
/// at full.
///
/// Porter and Duff's operators (`BLEND_CLEAR` to `BLEND_XOR`) put the
/// layer, at its opacity, and what is under it together by their
/// coverage: the layer where what is under is, what is under where the
/// layer is not, and the rest. Inside the clips the result takes the
/// place of what was under, so that the ones keeping nothing of what is
/// under where the layer is not - `BLEND_CLEAR`, `BLEND_COPY`,
/// `BLEND_SOURCE_IN`, `BLEND_DESTINATION_IN`, `BLEND_SOURCE_OUT` and
/// `BLEND_DESTINATION_ATOP` - clear it there, on all of the layer it
/// goes down on, or of the canvas's pens.
///
/// What a layer is blended with is what is under it on the layer it is
/// put down on: a group drawn on a layer of its own - SVG's `isolation:
/// isolate`, or a group with an opacity, a filter or a mask - is the
/// backdrop for what is blended inside it, starting clear.
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
/// BUGS:
/// Without the memory for the layer, what is drawn on it goes straight
/// onto what is under it, as `PushLayer` draws then, and is not blended.
///
/// SEE ALSO:
/// `PushLayer`, `PopLayer`, `FilterLayer`
///
/// EXAMPLES:
/// ```zig
/// // A shape multiplied onto the picture under it.
/// _ = vb.PushBlendLayer(canvas, 1, vector.BLEND_MULTIPLY);
/// _ = vb.FillPath(canvas, shape, &matrix, &paint, vector.RULE_NONZERO);
/// vb.PopLayer(canvas);
/// ```
pub fn PushBlendLayer(vb: *VectorBase, canvas: *vector.Canvas, opacity: f32, mode: u32) i32 {
    _ = vb;
    return _base.canvasOf(canvas).pushBlendLayer(opacity, mode);
}
