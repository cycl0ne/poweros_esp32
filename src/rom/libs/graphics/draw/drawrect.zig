// SPDX-License-Identifier: MPL-2.0
//! DrawRect: the outline of a rectangle.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const _draw = @import("_draw.zig");
const Rect = graphics.Rect;
const RastPort = rastport.RastPort;

/// The outline of a rectangle.
///
/// SYNOPSIS:
/// ```zig
/// fn DrawRect(gb: *GraphicsBase, rp: *RastPort, area: *const Rect) void
/// ```
///
/// SINCE: 0.9. LVO -76.
///
/// INPUTS:
/// - `rp` - the RastPort. Its pen, draw mode, line pattern and clip decide
///   the result.
/// - `area` - half-open, as every rectangle here is: the outline is drawn
///   just inside `max_x` and `max_y`. An empty one draws nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Four runs, with the corners belonging to the two horizontal ones so
/// that **no pixel is drawn twice**. That is not tidiness: under
/// `DRMD_COMPLEMENT` a pixel drawn twice is a pixel put back, and the
/// corners would be holes.
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
/// `RectFill`, `DrawHLine`
///
/// EXAMPLES:
/// ```zig
/// gb.DrawRect(rp, &.{ .min_x = 10, .min_y = 10, .max_x = 110, .max_y = 60 });
/// ```
pub fn DrawRect(gb: *GraphicsBase, rp: *RastPort, area: *const Rect) void {
    const graphics_lib = gb.iface();
    rp.last_error = graphics.GERR_OK;
    if (area.isEmpty()) return;
    const w = area.width();
    const h = area.height();
    graphics_lib.DrawHLine(@ptrCast(rp), area.min_x, area.min_y, w);
    if (h == 1) return;
    graphics_lib.DrawHLine(@ptrCast(rp), area.min_x, area.max_y - 1, w);
    if (h == 2) return;
    graphics_lib.DrawVLine(@ptrCast(rp), area.min_x, area.min_y + 1, h - 2);
    if (w == 1) return;
    graphics_lib.DrawVLine(@ptrCast(rp), area.max_x - 1, area.min_y + 1, h - 2);
}
