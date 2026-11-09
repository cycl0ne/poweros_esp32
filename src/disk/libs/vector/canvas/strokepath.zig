// SPDX-License-Identifier: MIT
//! StrokePath: a path stroked.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// The path stroked in its own units, then through the matrix (null: the identity), in the paint.
///
/// SYNOPSIS:
/// ```zig
/// fn StrokePath(vb: *VectorBase, canvas: *vector.Canvas, path: *const vector.Path, matrix: ?*const vector.Matrix, paint: *const vector.Paint, stroke: *const vector.Stroke) i32
/// ```
///
/// SINCE: 1.0. LVO -68.
///
/// INPUTS:
/// - `canvas` - what it is drawn on.
/// - `path` - what is stroked: its open contours with caps at their
///   ends, its closed ones joined all round.
/// - `matrix` - the path's units to pixels, or null when they are pixels.
/// - `paint` - what it is painted in, as `FillPath` paints.
/// - `stroke` - how (`vector.Stroke`), in the path's own units: the
///   width, the joins (`JOIN_MITER`, `JOIN_ROUND`, `JOIN_BEVEL`), the caps
///   (`CAP_BUTT`, `CAP_ROUND`, `CAP_SQUARE`) and the miter limit, in
///   stroke widths. 1.0 draws a dashed stroke whole.
///
/// RESULT:
/// `VECTOR_OK`, or `VECTORERR_NOMEM` as `FillPath` answers it.
///
/// BEHAVIOR:
/// The stroke is made of pieces in the path's units - a quadrilateral a
/// line, a piece at each corner, a cap at each open end - and those are
/// drawn through the matrix, so a stroke drawn through one that stretches
/// a way is stretched with it, as SVG draws one. A miter longer than the
/// limit is bevelled. A contour of one point is a dot when the caps are
/// round, and nothing otherwise; a stroke under a fiftieth of a pixel
/// wide is not drawn.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The path, the matrix, the paint and the stroke are the caller's and
/// only read; the pens are written.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FillPath`, `ClosePath`
///
/// EXAMPLES:
/// ```zig
/// const black = vector.Paint{};
/// const line = vector.Stroke{ .width = 2, .join = vector.JOIN_ROUND, .cap = vector.CAP_ROUND };
/// _ = vb.StrokePath(canvas, path, null, &black, &line);
/// ```
pub fn StrokePath(vb: *VectorBase, canvas: *vector.Canvas, path: *const vector.Path, matrix: ?*const vector.Matrix, paint: *const vector.Paint, stroke: *const vector.Stroke) i32 {
    _ = vb;
    const m: vector.Matrix = if (matrix) |it| it.* else .{};
    return _base.canvasOf(canvas).stroke(_base.pathOf(path), m, paint, stroke);
}
