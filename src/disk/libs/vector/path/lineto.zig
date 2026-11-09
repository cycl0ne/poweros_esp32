// SPDX-License-Identifier: MIT
//! LineTo: a line from the current point.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// A line from the current point to (x, y).
///
/// SYNOPSIS:
/// ```zig
/// fn LineTo(vb: *VectorBase, path: *vector.Path, x: f32, y: f32) void
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `path` - the path.
/// - `x`, `y` - where the line ends, in the path's units.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// (x, y) is the current point from then on. Before the path's first
/// `MoveTo` there is nowhere for a line to start, and it is passed over.
/// After a `ClosePath` the line starts a new contour where the closed
/// one began, as SVG's path data does.
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
/// Without the memory for it the line is not added, and the path
/// remembers that something did not fit (see `MoveTo`).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MoveTo`, `QuadTo`, `CubicTo`, `ClosePath`
///
/// EXAMPLES:
/// ```zig
/// vb.MoveTo(path, 0, 0);
/// vb.LineTo(path, 100, 0);
/// vb.LineTo(path, 50, 80);
/// vb.ClosePath(path);
/// ```
pub fn LineTo(vb: *VectorBase, path: *vector.Path, x: f32, y: f32) void {
    _ = vb;
    _base.pathOf(path).lineTo(.{ .x = x, .y = y });
}
