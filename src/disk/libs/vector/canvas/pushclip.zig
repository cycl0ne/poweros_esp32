// SPDX-License-Identifier: MIT
//! PushClip: what is drawn from now on shows only inside a path.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// What is drawn until PopClip shows only inside the path, through the matrix (null: the identity), by the rule (RULE_*).
///
/// SYNOPSIS:
/// ```zig
/// fn PushClip(vb: *VectorBase, canvas: *vector.Canvas, path: *const vector.Path, matrix: ?*const vector.Matrix, rule: u32) i32
/// ```
///
/// SINCE: 1.3. LVO -104.
///
/// INPUTS:
/// - `canvas` - the canvas.
/// - `path` - the clip's outline, in its own units.
/// - `matrix` - its units into pixels; null for the identity.
/// - `rule` - `RULE_NONZERO` or `RULE_EVENODD`: which of its inside is
///   inside, as `FillPath` has it - SVG's `clip-rule`.
///
/// RESULT:
/// `VECTOR_OK`; `VECTORERR_NOMEM` without the memory for the clip, which
/// then clips nothing more than the clip it is in; `VECTORERR_DEPTH`
/// past `MAX_CLIPS` clips one inside another, when it is nothing.
/// Whatever it answers, a `PopClip` goes with it.
///
/// BEHAVIOR:
/// The path's coverage is made, a byte a pixel, the edge smooth as a
/// fill's is - inside the clip already pushed on this layer, if there is
/// one. Every fill and stroke onto the layer drawn on now, and every
/// layer put down on it, shows from then on only as much as the clip
/// covers there, until the `PopClip` that goes with it.
///
/// A layer pushed after the clip is not clipped while it is drawn on,
/// only when it is put down: a group with its opacity on a layer goes
/// through the clip as a whole. A clip pushed on a layer goes with it
/// and is taken off by its `PopLayer` if not before.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The path and the matrix are the caller's and only read; the clip is
/// the canvas's, given back by the pop or by `DisposeCanvas`.
///
/// NOTES:
/// A clip is a byte a pixel of the whole canvas.
///
/// BUGS:
/// An edge the clip and what is drawn through it share is drawn by the
/// two coverages multiplied - a pixel half covered by both shows a
/// quarter, not a half - so a shape clipped by its own outline has a
/// fainter edge than unclipped. A browser draws it so; cairo, which cuts
/// one outline by the other first, does not.
///
/// SEE ALSO:
/// `PopClip`, `BeginMask`, `EndMask`, `PushLayer`, `FillPath`
///
/// EXAMPLES:
/// ```zig
/// vb.ClearPath(round);
/// vb.AddEllipse(round, 50, 50, 40, 40);
/// _ = vb.PushClip(canvas, round, null, vector.RULE_NONZERO);
/// _ = vb.FillPath(canvas, stripes, null, &red, vector.RULE_NONZERO);
/// vb.PopClip(canvas);
/// ```
pub fn PushClip(vb: *VectorBase, canvas: *vector.Canvas, path: *const vector.Path, matrix: ?*const vector.Matrix, rule: u32) i32 {
    _ = vb;
    const m: vector.Matrix = if (matrix) |it| it.* else .{};
    return _base.canvasOf(canvas).pushClip(_base.pathOf(path), m, rule);
}
