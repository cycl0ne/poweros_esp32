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
///   (`CAP_BUTT`, `CAP_ROUND`, `CAP_SQUARE`), the miter limit, in stroke
///   widths, and since 1.1 the dashes (1.0 draws a dashed stroke whole).
///
/// RESULT:
/// `VECTOR_OK`, or `VECTORERR_NOMEM` as `FillPath` answers it.
///
/// BEHAVIOR:
/// The stroke is made of pieces in the path's units - one a line, the
/// corner's on its outer side, a cap at each open end - and those are
/// drawn through the matrix, so a stroke drawn through one that stretches
/// a way is stretched with it, as SVG draws one. A miter longer than the
/// limit is bevelled. Where a curve was broken into lines, they are
/// joined round whatever the join, as the curve turns. A contour of one
/// point is a dot when the caps are round, and nothing otherwise; a
/// stroke under a fiftieth of a pixel wide is not drawn.
///
/// Since 1.2 the pieces meet edge to edge: a line's is cut on the inside
/// of a corner where the next one's begins, so no pixel at the stroke's
/// edge is painted by two (1.1's overlapped there, and came out a little
/// heavy). A corner whose lines are too short for that - a curve tighter
/// than the stroke is wide, a sharp turn between short lines - still
/// overlaps.
///
/// Dashes are cut from each contour in the path's units, from
/// `dash_offset` along it, before it is stroked, so each dash has its
/// caps; they go on from one segment to the next and round a closed
/// contour, whose last dash is joined to its first. An odd count of
/// lengths is gone through twice, and lengths that are negative or come
/// to nothing draw the stroke whole, as SVG has it. A stroke is cut at
/// most 65536 times; past that it goes on as the dash or gap it is in.
///
/// With a layer pushed (`PushLayer`) it is drawn on the layer.
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
