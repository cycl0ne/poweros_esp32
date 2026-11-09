// SPDX-License-Identifier: MIT
//! ArcTo: SVG's elliptical arc from the current point.

const sdk = @import("sdk");
const vector = sdk.vector;
const draw = @import("vector");
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// SVG's elliptical arc from the current point to (x, y): the radii, the ellipse's angle in degrees, ARC_LARGE and ARC_SWEEP.
///
/// SYNOPSIS:
/// ```zig
/// fn ArcTo(vb: *VectorBase, path: *vector.Path, rx: f32, ry: f32, angle: f32, flags: u32, x: f32, y: f32) void
/// ```
///
/// SINCE: 1.1. LVO -72.
///
/// INPUTS:
/// - `path` - the path.
/// - `rx`, `ry` - the ellipse's radii across and down, in the path's
///   units; their sign is taken off.
/// - `angle` - how far the ellipse is turned, in degrees, clockwise on
///   the screen.
/// - `flags` - `ARC_LARGE` for the arc of more than half the ellipse
///   rather than less, `ARC_SWEEP` for the one going the way angles rise
///   (clockwise on the screen) rather than the other.
/// - `x`, `y` - where the arc ends.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// SVG's `A`: of the two ellipses of these radii and this angle through
/// the current point and (x, y), and the two arcs of each between them,
/// the one the flags pick. Radii too small to reach from one end to the
/// other are made just large enough, so the arc is half an ellipse; a
/// radius of 0 makes a line, and an arc ending where it starts is
/// nothing. It is added as a cubic curve for every quarter turn or less
/// of it, kept as curves until drawn. Without a current point it is
/// passed over, and after a `ClosePath` it starts a new contour, as
/// `LineTo` does.
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
/// Without the memory for it the arc is added as far as it fitted, a
/// curve at a time, and the path remembers that something did not fit
/// (see `MoveTo`).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CubicTo`, `AddEllipse`, `AddPathData`
///
/// EXAMPLES:
/// ```zig
/// // A half circle of radius 10 over the top from (0, 10) to (20, 10).
/// vb.MoveTo(path, 0, 10);
/// vb.ArcTo(path, 10, 10, 0, vector.ARC_SWEEP, 20, 10);
/// ```
pub fn ArcTo(vb: *VectorBase, path: *vector.Path, rx: f32, ry: f32, angle: f32, flags: u32, x: f32, y: f32) void {
    _ = vb;
    draw.shapes.arcTo(_base.pathOf(path), rx, ry, angle, flags & vector.ARC_LARGE != 0, flags & vector.ARC_SWEEP != 0, .{ .x = x, .y = y });
}
