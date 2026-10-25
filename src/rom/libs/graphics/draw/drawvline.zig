// SPDX-License-Identifier: MPL-2.0
//! DrawVLine: a run of pixels downward. `DrawHLine` turned on its side.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const span = _draw.span;
const RastPort = _draw.RastPort;
const _draw = @import("_draw.zig");
const rastport = @import("../rastport/_rastport.zig");

/// A run of pixels downward. `DrawHLine` turned on its side.
///
/// SYNOPSIS:
/// ```zig
/// fn DrawVLine(gb: *GraphicsBase, rp: *RastPort, x: i32, y: i32, length: i32) void
/// ```
///
/// SINCE: 0.9. LVO -72.
///
/// INPUTS:
/// - `rp` - the RastPort. Its pen, draw mode, line pattern and clip decide
///   the result.
/// - `x` - its column.
/// - `y` - where the run starts, down.
/// - `length` - how many pixels. 0 or less draws nothing.
///
/// RESULT:
/// Nothing. What the clip keeps out is not drawn, which is not an error.
///
/// BEHAVIOR:
/// `DrawHLine` turned on its side: patterned like a line, the pattern
/// counting from the start of the run.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the RastPort's lock
///   (`RPTAG_Lock`), if it has one.
/// - Interrupts: no. The work is unbounded, and it hands the rows it wrote on
///   to the display at the end.
/// - Locks: the RastPort's own, taken here; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DrawHLine`, `DrawRect`
///
/// EXAMPLES:
/// ```zig
/// gb.DrawVLine(rp, 10, 20, 50);
/// ```
pub fn DrawVLine(gb: *GraphicsBase, rp: *RastPort, x: i32, y: i32, length: i32) void {
    const held = rastport.hold(gb, rp);
    defer rastport.letGo(gb, held);
    rp.last_error = graphics.GERR_OK;
    if (length <= 0) return;
    span(gb, rp, .{ .min_x = x, .min_y = y, .max_x = x + 1, .max_y = y + length }, false);
}
