// SPDX-License-Identifier: MIT
//! QuadTo: a quadratic curve from the current point.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// A quadratic curve from the current point to (x, y), pulled toward (x1, y1).
///
/// SYNOPSIS:
/// ```zig
/// fn QuadTo(vb: *VectorBase, path: *vector.Path, x1: f32, y1: f32, x: f32, y: f32) void
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `path` - the path.
/// - `x1`, `y1` - the control point, in the path's units.
/// - `x`, `y` - where the curve ends.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The curve leaves the current point toward (x1, y1) and arrives at
/// (x, y) from it, as TrueType's and SVG's `Q` curves do; (x, y) is the
/// current point from then on. It is kept as a curve and broken into
/// lines only when drawn. Without a current point it is passed over, and
/// after a `ClosePath` it starts a new contour, as `LineTo` does.
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
/// `CubicTo`, `LineTo`
///
/// EXAMPLES:
/// ```zig
/// vb.MoveTo(path, 0, 50);
/// vb.QuadTo(path, 50, 0, 100, 50);
/// ```
pub fn QuadTo(vb: *VectorBase, path: *vector.Path, x1: f32, y1: f32, x: f32, y: f32) void {
    _ = vb;
    _base.pathOf(path).quadTo(.{ .x = x1, .y = y1 }, .{ .x = x, .y = y });
}
