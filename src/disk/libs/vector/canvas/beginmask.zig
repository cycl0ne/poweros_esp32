// SPDX-License-Identifier: MIT
//! BeginMask: what is drawn from now on makes a mask.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// What is drawn until EndMask makes a mask rather than being seen.
///
/// SYNOPSIS:
/// ```zig
/// fn BeginMask(vb: *VectorBase, canvas: *vector.Canvas) i32
/// ```
///
/// SINCE: 1.3. LVO -112.
///
/// INPUTS:
/// - `canvas` - the canvas.
///
/// RESULT:
/// `VECTOR_OK`; `VECTORERR_NOMEM` without the memory for the mask's
/// layer; `VECTORERR_DEPTH` past `MAX_LAYERS` layers one inside another.
/// Whatever it answers, an `EndMask` goes with it, and a `PopClip` with
/// that.
///
/// BEHAVIOR:
/// A layer is pushed, clear, that is never put down: every fill and
/// stroke until the `EndMask` that goes with it is drawn onto it, not
/// clipped by the clips already pushed, and `EndMask` turns it into a
/// clip. Layers, clips and masks may be pushed and popped inside it, as
/// anywhere.
///
/// Without the layer's memory, or past the most layers, what is drawn
/// until `EndMask` is drawn nowhere, and the mask clips nothing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The layer is the canvas's, given back by `EndMask` or by
/// `DisposeCanvas`.
///
/// NOTES:
/// The layer is four bytes a pixel of the whole canvas until it ends,
/// and the mask then one.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `EndMask`, `PopClip`, `PushClip`, `PushLayer`
///
/// EXAMPLES:
/// ```zig
/// _ = vb.BeginMask(canvas);
/// _ = vb.FillPath(canvas, fade, null, &white_to_black, vector.RULE_NONZERO);
/// _ = vb.EndMask(canvas, vector.MASK_LUMINANCE);
/// _ = vb.FillPath(canvas, picture, null, &red, vector.RULE_NONZERO);
/// vb.PopClip(canvas);
/// ```
pub fn BeginMask(vb: *VectorBase, canvas: *vector.Canvas) i32 {
    _ = vb;
    return _base.canvasOf(canvas).beginMask();
}
