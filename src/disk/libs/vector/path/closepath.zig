// SPDX-License-Identifier: MIT
//! ClosePath: the contour closed.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// The contour closed back to where it started.
///
/// SYNOPSIS:
/// ```zig
/// fn ClosePath(vb: *VectorBase, path: *vector.Path) void
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `path` - the path.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A straight line back to the contour's start closes it: a stroke joins
/// its ends there instead of giving them caps. The current point is the
/// start from then on, and the next segment starts a new contour there.
/// A contour already closed, or no contour at all, is left as it is.
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
/// `MoveTo`, `StrokePath`
///
/// EXAMPLES:
/// ```zig
/// vb.MoveTo(path, 0, 0);
/// vb.LineTo(path, 10, 0);
/// vb.LineTo(path, 10, 10);
/// vb.ClosePath(path);
/// ```
pub fn ClosePath(vb: *VectorBase, path: *vector.Path) void {
    _ = vb;
    _base.pathOf(path).close();
}
