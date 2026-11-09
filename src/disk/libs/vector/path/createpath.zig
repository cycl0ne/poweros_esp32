// SPDX-License-Identifier: MIT
//! CreatePath: an empty path.

const sdk = @import("sdk");
const vector = sdk.vector;
const draw = @import("vector");
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// An empty path; null without the memory for one.
///
/// SYNOPSIS:
/// ```zig
/// fn CreatePath(vb: *VectorBase) ?*vector.Path
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The path, or null when there was not the memory for it.
///
/// BEHAVIOR:
/// A path holds contours of lines and curves in the caller's own units,
/// built a segment at a time with `MoveTo`, `LineTo`, `QuadTo`, `CubicTo`
/// and `ClosePath`. Curves stay curves: the path is broken into lines
/// only when it is drawn, at the size it is drawn at, so one path is
/// drawn at any size. Its memory grows as segments are added.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's until `DisposePath`, and one task's at a time: the
/// library holds no lock for it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DisposePath`, `ClearPath`, `MoveTo`, `FillPath`, `StrokePath`
///
/// EXAMPLES:
/// ```zig
/// const path = vb.CreatePath() orelse return error.NoMemory;
/// defer vb.DisposePath(path);
/// ```
pub fn CreatePath(vb: *VectorBase) ?*vector.Path {
    const path = draw.Path.create(_base.memoryOf(vb)) orelse return null;
    return @ptrCast(path);
}
