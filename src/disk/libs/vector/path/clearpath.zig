// SPDX-License-Identifier: MIT
//! ClearPath: the path emptied, its memory kept.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// The path emptied, its memory kept for the next one built in it.
///
/// SYNOPSIS:
/// ```zig
/// fn ClearPath(vb: *VectorBase, path: *vector.Path) void
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `path` - the path.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Every contour goes, and with it the current point and a want of
/// memory the path had met: it is as `CreatePath` made it, but it keeps
/// the memory it had grown to. A program that builds a path anew for
/// every frame clears one rather than making and giving back another.
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
/// `CreatePath`, `DisposePath`
///
/// EXAMPLES:
/// ```zig
/// vb.ClearPath(path);
/// vb.MoveTo(path, 0, 0);
/// ```
pub fn ClearPath(vb: *VectorBase, path: *vector.Path) void {
    _ = vb;
    _base.pathOf(path).clear();
}
