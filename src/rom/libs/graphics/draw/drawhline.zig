// SPDX-License-Identifier: MPL-2.0
//! DrawHLine: a run of pixels rightward.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const span = _draw.span;
const RastPort = _draw.RastPort;
const _draw = @import("_draw.zig");

/// A run of pixels rightward.
///
/// SYNOPSIS:
/// ```zig
/// fn DrawHLine(gb: *GraphicsBase, rp: *RastPort, x: i32, y: i32, length: i32) void
/// ```
///
/// SINCE: 0.9. LVO -68.
///
/// INPUTS:
/// - `rp` - the RastPort. Its pen, draw mode, line pattern and clip decide
///   the result.
/// - `x` - where the run starts, across.
/// - `y` - its row.
/// - `length` - how many pixels. 0 or less draws nothing.
///
/// RESULT:
/// Nothing. What the clip keeps out is not drawn, which is not an error.
///
/// BEHAVIOR:
/// Patterned like a line, and the pattern counts from the start of the run
/// rather than from where the clip let it begin - so a run cut in two by
/// the clip is dotted as though it had not been.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. The work is unbounded, and it hands the rows it wrote on
///   to the display at the end.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DrawVLine`, `DrawRect`, `RectFill`
///
/// EXAMPLES:
/// ```zig
/// gb.DrawHLine(rp, 10, 20, 100);
/// ```
pub fn DrawHLine(gb: *GraphicsBase, rp: *RastPort, x: i32, y: i32, length: i32) void {
    rp.last_error = graphics.GERR_OK;
    if (length <= 0) return;
    span(gb, rp, .{ .min_x = x, .min_y = y, .max_x = x + length, .max_y = y + 1 }, true);
}
