// SPDX-License-Identifier: MIT
//! PathLength: how long a path is.

const sdk = @import("sdk");
const vector = sdk.vector;
const draw = @import("vector");
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// The length of the path through the matrix (null: the identity).
///
/// SYNOPSIS:
/// ```zig
/// fn PathLength(vb: *VectorBase, path: *const vector.Path, matrix: ?*const vector.Matrix) f32
/// ```
///
/// SINCE: 1.5. LVO -132.
///
/// INPUTS:
/// - `path` - the path.
/// - `matrix` - the path's units to the ones the length is wanted in, or
///   null for the path's own.
///
/// RESULT:
/// The length; 0 for an empty path or one of points alone.
///
/// BEHAVIOR:
/// Every contour's lines and curves are measured through the matrix,
/// each curve to within a hundredth of a unit, and added up. A close is
/// the line back to where its contour began; a move adds nothing. This
/// is the length SVG's `pathLength` stands for, and what a text on a
/// path is laid along.
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
/// `PathPointAt`, `PathVertices`, `PathBounds`
///
/// EXAMPLES:
/// ```zig
/// // A dash pattern given for pathLength="100", made the path's own.
/// const k = vb.PathLength(path, null) / 100;
/// ```
pub fn PathLength(vb: *VectorBase, path: *const vector.Path, matrix: ?*const vector.Matrix) f32 {
    _ = vb;
    const applied: vector.Matrix = if (matrix) |given| given.* else .{};
    return draw.measure.length(_base.pathOf(path), applied);
}
