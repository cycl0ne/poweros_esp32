// SPDX-License-Identifier: MIT
//! AddRect: a rectangle, its corners rounded or not, as a contour.

const sdk = @import("sdk");
const vector = sdk.vector;
const draw = @import("vector");
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// A closed rectangle, its corners rounded rx across and ry down; SVG's rect.
///
/// SYNOPSIS:
/// ```zig
/// fn AddRect(vb: *VectorBase, path: *vector.Path, rect: *const vector.Rect, rx: f32, ry: f32) void
/// ```
///
/// SINCE: 1.1. LVO -76.
///
/// INPUTS:
/// - `path` - the path.
/// - `rect` - where it is and how large (`vector.Rect`), in the path's
///   units.
/// - `rx`, `ry` - how far round each corner goes, across and down; 0 for
///   square corners.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A contour of its own, closed, as SVG draws a `rect`: from the top
/// left - after its rounding - going right, so clockwise on the screen.
/// The corners are quarters of an ellipse, `rx` and `ry` each held to
/// half the side it is along, and square when either is 0 or less. A
/// width or a height of 0 or less adds nothing. The current point is the
/// contour's start afterwards.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The rectangle is the caller's and only read.
///
/// NOTES:
/// SVG's `rx` given alone stands for `ry` too, and the other way round:
/// a program reading SVG passes the one for both.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddEllipse`, `MoveTo`
///
/// EXAMPLES:
/// ```zig
/// const box = vector.Rect{ .x = 10, .y = 10, .width = 80, .height = 40 };
/// vb.AddRect(path, &box, 6, 6);
/// ```
pub fn AddRect(vb: *VectorBase, path: *vector.Path, rect: *const vector.Rect, rx: f32, ry: f32) void {
    _ = vb;
    draw.shapes.addRect(_base.pathOf(path), rect.*, rx, ry);
}
