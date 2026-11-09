// SPDX-License-Identifier: MIT
//! DisposeCanvas: a canvas given back.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// A canvas given back; its pens stay the caller's. Null does nothing.
///
/// SYNOPSIS:
/// ```zig
/// fn DisposeCanvas(vb: *VectorBase, canvas: ?*vector.Canvas) void
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// - `canvas` - what `CreateCanvasTagList` answered, or null.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The canvas's working memory goes back. The pens it drew on are left
/// as they are, with what was drawn on them.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The canvas is gone: the handle must not be used again. The pens are
/// the caller's to free.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateCanvasTagList`
///
/// EXAMPLES:
/// ```zig
/// vb.DisposeCanvas(canvas);
/// ```
pub fn DisposeCanvas(vb: *VectorBase, canvas: ?*vector.Canvas) void {
    _ = vb;
    if (canvas) |it| _base.canvasOf(it).destroy();
}
