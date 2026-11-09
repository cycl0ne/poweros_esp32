// SPDX-License-Identifier: MIT
//! AddEllipse: an ellipse as a contour.

const sdk = @import("sdk");
const vector = sdk.vector;
const draw = @import("vector");
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// A closed ellipse round (cx, cy); SVG's ellipse.
///
/// SYNOPSIS:
/// ```zig
/// fn AddEllipse(vb: *VectorBase, path: *vector.Path, cx: f32, cy: f32, rx: f32, ry: f32) void
/// ```
///
/// SINCE: 1.1. LVO -80.
///
/// INPUTS:
/// - `path` - the path.
/// - `cx`, `cy` - its centre, in the path's units.
/// - `rx`, `ry` - its radii across and down; the same for a circle.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A contour of its own, closed, of four cubic curves, as SVG draws an
/// `ellipse` or a `circle`: from its rightmost point, clockwise on the
/// screen. A radius of 0 or less adds nothing. The current point is the
/// rightmost point afterwards.
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
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddRect`, `ArcTo`
///
/// EXAMPLES:
/// ```zig
/// vb.AddEllipse(path, 50, 50, 20, 20); // a circle
/// ```
pub fn AddEllipse(vb: *VectorBase, path: *vector.Path, cx: f32, cy: f32, rx: f32, ry: f32) void {
    _ = vb;
    draw.shapes.addEllipse(_base.pathOf(path), .{ .x = cx, .y = cy }, rx, ry);
}
