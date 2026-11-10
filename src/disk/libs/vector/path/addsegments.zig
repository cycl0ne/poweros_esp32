// SPDX-License-Identifier: MIT
//! AddSegments: a path's segments handed over whole.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// Segments onto the path in one call: a verb each (SEG_*) and the points they take, in order; VECTORERR_SYNTAX at a verb it does not know or short of points, the path kept up to it.
///
/// SYNOPSIS:
/// ```zig
/// fn AddSegments(vb: *VectorBase, path: *vector.Path, verbs: [*]const u8, verb_count: u32, points: [*]const vector.Point, point_count: u32) i32
/// ```
///
/// SINCE: 1.2. LVO -100.
///
/// INPUTS:
/// - `path` - the path the segments are added to.
/// - `verbs`, `verb_count` - a byte a segment: `SEG_MOVE`, `SEG_LINE`,
///   `SEG_QUAD`, `SEG_CUBIC` or `SEG_CLOSE`.
/// - `points`, `point_count` - the points the verbs take, one verb's
///   after another's: a move and a line one, a quadratic curve two (its
///   control point, then its end), a cubic one three (its two control
///   points, then its end), a close none.
///
/// RESULT:
/// `VECTOR_OK`; `VECTORERR_SYNTAX` at a verb that is none of these or
/// that has fewer points left than it takes; `VECTORERR_NOMEM` when a
/// segment did not fit.
///
/// BEHAVIOR:
/// The path comes out as the same calls one at a time - `MoveTo`,
/// `LineTo`, `QuadTo`, `CubicTo`, `ClosePath` - would make it, and is
/// added to what it holds already: a segment with no move before it is
/// passed over, and one after a close starts where the closed contour
/// began. The room for all of it is taken at once.
///
/// At an error the segments before it are kept. Points past the ones
/// the last verb takes are not looked at.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The verbs and the points are the caller's and only read; the path
/// keeps copies.
///
/// NOTES:
/// For a path a program keeps as data, or reads out of a file: one call
/// through the jump table for all of it, rather than one a segment.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MoveTo`, `AddPathData`, `ClearPath`
///
/// EXAMPLES:
/// ```zig
/// const verbs = [_]u8{ vector.SEG_MOVE, vector.SEG_LINE, vector.SEG_LINE, vector.SEG_CLOSE };
/// const points = [_]vector.Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 5, .y = 8 } };
/// if (vb.AddSegments(path, &verbs, verbs.len, &points, points.len) != vector.VECTOR_OK) return;
/// ```
pub fn AddSegments(vb: *VectorBase, path: *vector.Path, verbs: [*]const u8, verb_count: u32, points: [*]const vector.Point, point_count: u32) i32 {
    _ = vb;
    return _base.pathOf(path).addSegments(verbs[0..verb_count], points[0..point_count]);
}
