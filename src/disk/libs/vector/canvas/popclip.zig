// SPDX-License-Identifier: MIT
//! PopClip: the last clip or mask pushed taken off.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// The last clip or mask pushed taken off.
///
/// SYNOPSIS:
/// ```zig
/// fn PopClip(vb: *VectorBase, canvas: *vector.Canvas) void
/// ```
///
/// SINCE: 1.3. LVO -108.
///
/// INPUTS:
/// - `canvas` - the canvas.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The clip pushed last, by `PushClip` or `EndMask`, is given back, and
/// what is drawn from then on is clipped by the one it was in, if any.
/// A clip that had no memory, or was past the most, is only ended. With
/// no clip pushed it does nothing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The clip's memory goes back to the canvas's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `PushClip`, `EndMask`
///
/// EXAMPLES:
/// ```zig
/// vb.PopClip(canvas);
/// ```
pub fn PopClip(vb: *VectorBase, canvas: *vector.Canvas) void {
    _ = vb;
    _base.canvasOf(canvas).popClip();
}
