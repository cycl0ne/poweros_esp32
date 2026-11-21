// SPDX-License-Identifier: MIT
//! PathPointAt: where a distance along a path comes to.

const sdk = @import("sdk");
const vector = sdk.vector;
const draw = @import("vector");
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// The point a distance along the path comes to through the matrix, and the way the path goes there.
///
/// SYNOPSIS:
/// ```zig
/// fn PathPointAt(vb: *VectorBase, path: *const vector.Path, matrix: ?*const vector.Matrix, distance: f32, point: *vector.Point, angle: *f32) bool
/// ```
///
/// SINCE: 1.5. LVO -136.
///
/// INPUTS:
/// - `path` - the path.
/// - `matrix` - the path's units to the ones wanted, or null for the
///   path's own.
/// - `distance` - how far along, in those units.
/// - `point` - where the place is put.
/// - `angle` - where the way the path goes there is put, in degrees
///   clockwise from across, 0 up to 360.
///
/// RESULT:
/// True and both filled in; false for a distance before the start or
/// past the end, or a path of no length, and both left as they were.
///
/// BEHAVIOR:
/// The path is walked as `PathLength` measures it, the contours one after
/// another, to the place `distance` along it. At a vertex the way is the
/// one out of it; at the path's very end, the one into it. On a curve
/// the place is on the curve itself and the way is its tangent there,
/// not that of the short lines it is measured by. A segment of no length
/// has no way and is passed over. This is how SVG's
/// `textPath` places each glyph: its middle at the distance, turned the
/// way the path goes.
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
/// NOTES:
/// Each call walks the path from its start: a text of many glyphs on a
/// long path costs the glyphs times the path.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `PathLength`, `PathVertices`
///
/// EXAMPLES:
/// ```zig
/// var at: vector.Point = undefined;
/// var turn: f32 = undefined;
/// if (vb.PathPointAt(path, null, offset + advance / 2, &at, &turn)) {
///     // The glyph drawn turned by `turn` about `at`.
/// }
/// ```
pub fn PathPointAt(vb: *VectorBase, path: *const vector.Path, matrix: ?*const vector.Matrix, distance: f32, point: *vector.Point, angle: *f32) bool {
    _ = vb;
    const applied: vector.Matrix = if (matrix) |given| given.* else .{};
    const place = draw.measure.pointAt(_base.pathOf(path), applied, distance) orelse return false;
    point.* = place.point;
    angle.* = place.angle;
    return true;
}
