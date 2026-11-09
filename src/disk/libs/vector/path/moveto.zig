// SPDX-License-Identifier: MIT
//! MoveTo: a new contour started.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// A new contour started at (x, y).
///
/// SYNOPSIS:
/// ```zig
/// fn MoveTo(vb: *VectorBase, path: *vector.Path, x: f32, y: f32) void
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `path` - the path.
/// - `x`, `y` - where the contour starts, in the path's units.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A contour still open ends where it is: a fill closes it with a
/// straight line, a stroke gives it its caps. (x, y) is the current
/// point, where the next segment starts. A move followed by nothing is a
/// contour of one point, which a stroke with round caps draws as a dot.
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
/// Without the memory for it the move is not added, and the path
/// remembers that something did not fit: `FillPath` and `StrokePath`
/// draw what there is and answer `VECTORERR_NOMEM`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LineTo`, `CubicTo`, `ClosePath`
///
/// EXAMPLES:
/// ```zig
/// vb.MoveTo(path, 10, 10);
/// vb.LineTo(path, 90, 10);
/// ```
pub fn MoveTo(vb: *VectorBase, path: *vector.Path, x: f32, y: f32) void {
    _ = vb;
    _base.pathOf(path).moveTo(.{ .x = x, .y = y });
}
