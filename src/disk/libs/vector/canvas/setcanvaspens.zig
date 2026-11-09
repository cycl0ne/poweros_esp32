// SPDX-License-Identifier: MIT
//! SetCanvasPens: the pens a canvas draws on from now on.

const sdk = @import("sdk");
const vector = sdk.vector;
const graphics = sdk.graphics;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// The pens the canvas draws on from now on; null draws nothing.
///
/// SYNOPSIS:
/// ```zig
/// fn SetCanvasPens(vb: *VectorBase, canvas: *vector.Canvas, pens: ?[*]graphics.Pen, bytes_per_row: u32) void
/// ```
///
/// SINCE: 1.0. LVO -60.
///
/// INPUTS:
/// - `canvas` - the canvas.
/// - `pens` - its width by its height of them, 0xAARRGGBB, or null.
/// - `bytes_per_row` - from one row of them to the next; 0 for four
///   times the canvas's width.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The canvas keeps its size and its working memory, and draws on these
/// pens instead: a program that draws frame after frame into buffers of
/// one size hands each over in turn. With null, a fill or a stroke
/// draws nothing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pens stay the caller's, and must last while they are drawn on.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateCanvasTagList`, `FillPath`
///
/// EXAMPLES:
/// ```zig
/// vb.SetCanvasPens(canvas, frame.pens, frame.bytes_per_row);
/// ```
pub fn SetCanvasPens(vb: *VectorBase, canvas: *vector.Canvas, pens: ?[*]graphics.Pen, bytes_per_row: u32) void {
    _ = vb;
    _base.canvasOf(canvas).setPens(pens, bytes_per_row);
}
