// SPDX-License-Identifier: MIT
//! DisposePath: a path given back.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// A path given back. Null does nothing.
///
/// SYNOPSIS:
/// ```zig
/// fn DisposePath(vb: *VectorBase, path: ?*vector.Path) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `path` - what `CreatePath` answered, or null.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The path's memory goes back, its segments with it. What was drawn
/// with it stays on the pens it was drawn on.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The path is gone: the handle must not be used again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreatePath`, `ClearPath`
///
/// EXAMPLES:
/// ```zig
/// vb.DisposePath(path);
/// ```
pub fn DisposePath(vb: *VectorBase, path: ?*vector.Path) void {
    _ = vb;
    if (path) |it| _base.pathOf(it).destroy();
}
