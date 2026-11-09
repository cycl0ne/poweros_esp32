// SPDX-License-Identifier: MIT
//! FillPath: a path filled.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// The path filled through the matrix (null: the identity) in the paint, by the rule (RULE_*).
///
/// SYNOPSIS:
/// ```zig
/// fn FillPath(vb: *VectorBase, canvas: *vector.Canvas, path: *const vector.Path, matrix: ?*const vector.Matrix, paint: *const vector.Paint, rule: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -64.
///
/// INPUTS:
/// - `canvas` - what it is drawn on.
/// - `path` - what is filled. Every contour is closed for it, open or
///   not, with a straight line back to its start.
/// - `matrix` - the path's units to pixels, or null when they are pixels.
/// - `paint` - what it is painted in (`vector.Paint`): in 1.0 its colour,
///   at its colour's coverage times its opacity, whatever its kind.
/// - `rule` - `RULE_NONZERO`: inside wherever the contours wind round a
///   point; `RULE_EVENODD`: wherever they wind round it an odd number of
///   times, so a contour inside another is a hole.
///
/// RESULT:
/// `VECTOR_OK`, or `VECTORERR_NOMEM` when the path had run out of memory
/// as it was built or there was no room to break it into lines: what
/// there was is drawn.
///
/// BEHAVIOR:
/// The curves are broken into lines at the size they are drawn at, and
/// every pixel is painted by how much of it the shape covers, so the
/// edges are smooth. The paint goes over what each pen held: a pen's
/// share of the shape times the paint's opacity of it, mixed with the
/// pen by its own coverage. Pixels off the canvas are passed over; so
/// is everything with no pens set.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The path, the matrix and the paint are the caller's and only read;
/// the pens are written.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StrokePath`, `CreateCanvasTagList`, `MoveTo`
///
/// EXAMPLES:
/// ```zig
/// const red = vector.Paint{ .colour = .{ .r = 1 } };
/// const twice = vector.Matrix.scale(2, 2);
/// _ = vb.FillPath(canvas, path, &twice, &red, vector.RULE_NONZERO);
/// ```
pub fn FillPath(vb: *VectorBase, canvas: *vector.Canvas, path: *const vector.Path, matrix: ?*const vector.Matrix, paint: *const vector.Paint, rule: u32) i32 {
    _ = vb;
    const m: vector.Matrix = if (matrix) |it| it.* else .{};
    return _base.canvasOf(canvas).fill(_base.pathOf(path), m, paint, rule);
}
