// SPDX-License-Identifier: MIT
//! PathBounds: the box a path's curves keep within.

const sdk = @import("sdk");
const vector = sdk.vector;
const draw = @import("vector");
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// The bounds of the path's curves through the matrix (null: the identity); false for an empty path.
///
/// SYNOPSIS:
/// ```zig
/// fn PathBounds(vb: *VectorBase, path: *const vector.Path, matrix: ?*const vector.Matrix, bounds: *vector.Rect) bool
/// ```
///
/// SINCE: 1.1. LVO -88.
///
/// INPUTS:
/// - `path` - the path.
/// - `matrix` - the path's units to the ones the bounds are wanted in, or
///   null for the path's own.
/// - `bounds` - where they are put.
///
/// RESULT:
/// True and `bounds` filled in; false for a path with no point, and
/// `bounds` left as it was.
///
/// BEHAVIOR:
/// The smallest rectangle round the path's curves as drawn through the
/// matrix - of the curves themselves, not of their control points -
/// which is SVG's bounding box, the one `objectBoundingBox` gradients
/// are laid over. Every point counts, a contour's move with the rest. A
/// path with nothing but a point has bounds of no size.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The path and the matrix are the caller's and only read.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FillPath`, `AddPathData`
///
/// EXAMPLES:
/// ```zig
/// // A gradient laid over the shape's box, as objectBoundingBox has it.
/// var box: vector.Rect = undefined;
/// if (vb.PathBounds(path, null, &box)) {
///     paint.matrix = vector.Matrix.translate(box.x, box.y).then(vector.Matrix.scale(box.width, box.height));
/// }
/// ```
pub fn PathBounds(vb: *VectorBase, path: *const vector.Path, matrix: ?*const vector.Matrix, bounds: *vector.Rect) bool {
    _ = vb;
    const m: vector.Matrix = if (matrix) |it| it.* else .{};
    bounds.* = draw.bounds(_base.pathOf(path), m) orelse return false;
    return true;
}
