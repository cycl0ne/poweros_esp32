// SPDX-License-Identifier: MIT
//! CubicTo: a cubic curve from the current point.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// A cubic curve from the current point to (x, y), leaving toward (x1, y1) and arriving from (x2, y2).
///
/// SYNOPSIS:
/// ```zig
/// fn CubicTo(vb: *VectorBase, path: *vector.Path, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) void
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `path` - the path.
/// - `x1`, `y1` - the first control point, in the path's units.
/// - `x2`, `y2` - the second.
/// - `x`, `y` - where the curve ends.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A Bézier curve, as SVG's `C` and Lottie's vertices draw: (x, y) is the
/// current point from then on. It is kept as a curve and broken into
/// lines only when drawn, enough of them that none strays from it by
/// more than a tenth of a pixel at the size it is drawn at (a quarter
/// before 1.2). Without a
/// current point it is passed over, and after a `ClosePath` it starts a
/// new contour, as `LineTo` does.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's, as before.
///
/// NOTES:
/// Without the memory for it the curve is not added, and the path
/// remembers that something did not fit (see `MoveTo`).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `QuadTo`, `LineTo`
///
/// EXAMPLES:
/// ```zig
/// // A quarter of a circle of radius 100 round (0, 0).
/// vb.MoveTo(path, 100, 0);
/// vb.CubicTo(path, 100, 55.23, 55.23, 100, 0, 100);
/// ```
pub fn CubicTo(vb: *VectorBase, path: *vector.Path, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) void {
    _ = vb;
    _base.pathOf(path).cubicTo(.{ .x = x1, .y = y1 }, .{ .x = x2, .y = y2 }, .{ .x = x, .y = y });
}
