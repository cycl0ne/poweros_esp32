// SPDX-License-Identifier: MIT
//! EndMask: the drawing since BeginMask made a mask, and pushed.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// The drawing since BeginMask made a mask (MASK_*) that clips what is drawn until PopClip.
///
/// SYNOPSIS:
/// ```zig
/// fn EndMask(vb: *VectorBase, canvas: *vector.Canvas, kind: u32) i32
/// ```
///
/// SINCE: 1.3. LVO -116.
///
/// INPUTS:
/// - `canvas` - the canvas.
/// - `kind` - `MASK_ALPHA`, how much was drawn at each pixel;
///   `MASK_LUMINANCE`, that times the luminance of its colour - white
///   shows all, black nothing, as SVG's `mask`. With `MASK_INVERT`,
///   either the other way round.
///
/// RESULT:
/// `VECTOR_OK`; `VECTORERR_NOMEM` when the mask's layer or the mask had
/// no memory, when it clips nothing more than the clip it is in;
/// `VECTORERR_DEPTH` past `MAX_CLIPS` clips one inside another, or with
/// no mask begun - nothing is then pushed for it. Otherwise, whatever it
/// answers, a `PopClip` goes with it.
///
/// BEHAVIOR:
/// The layer `BeginMask` pushed is ended and given back; what was drawn
/// on it becomes a clip, a byte a pixel - its coverage, or its
/// luminance (0.2125 red, 0.7154 green, 0.0721 blue) times that - inside
/// the clip pushed already on the layer under it. It is then pushed as
/// `PushClip` pushes a path's: what is drawn from now on shows through
/// it until the `PopClip`. Layers pushed inside the mask and not popped
/// are popped first; the clips pushed inside it are taken off.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The mask is the canvas's, given back by the pop or by
/// `DisposeCanvas`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BeginMask`, `PopClip`, `PushClip`
///
/// EXAMPLES:
/// ```zig
/// _ = vb.BeginMask(canvas);
/// _ = vb.FillPath(canvas, letters, null, &white, vector.RULE_NONZERO);
/// _ = vb.EndMask(canvas, vector.MASK_ALPHA | vector.MASK_INVERT);
/// _ = vb.FillPath(canvas, plate, null, &grey, vector.RULE_NONZERO);
/// vb.PopClip(canvas);
/// ```
pub fn EndMask(vb: *VectorBase, canvas: *vector.Canvas, kind: u32) i32 {
    _ = vb;
    return _base.canvasOf(canvas).endMask(kind);
}
