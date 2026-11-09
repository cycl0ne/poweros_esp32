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
/// - `paint` - what it is painted in (`vector.Paint`): one colour, or
///   since 1.1 a linear or radial gradient with its stops, spread and
///   matrix (1.0 paints a gradient's colour), at the paint's opacity.
///   A gradient with no stops paints nothing, one with one paints its
///   colour, and one of no length or radius its last stop's colour, as
///   SVG has it.
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
/// A gradient is laid in its own units, taken into the path's by the
/// paint's matrix and then to pixels by this one: each pixel's centre
/// is taken back to see where along it the pixel is. Its colour there
/// comes from 256 made from the stops for the fill, mixed as they are
/// and not premultiplied. A radial gradient's focus outside its circle
/// makes a cone, beside which nothing is painted, as SVG 2 draws it.
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
/// The path, the matrix and the paint are the caller's and only read;
/// the pens are written.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StrokePath`, `CreateCanvasTagList`, `MoveTo`, `PathBounds`, `PushLayer`
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
