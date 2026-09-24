// SPDX-License-Identifier: MPL-2.0
//! DrawCircle: a circle's outline.

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
const circlePoints = _draw.circlePoints;
const handOn = _draw.handOn;

/// A circle's outline.
///
/// SYNOPSIS:
/// ```zig
/// fn DrawCircle(gb: *GraphicsBase, rp: *RastPort, cx: i32, cy: i32, radius: i32) void
/// ```
///
/// SINCE: 0.9. LVO -80.
///
/// INPUTS:
/// - `rp` - the RastPort. Its pen, draw mode, line pattern and clip decide
///   the result.
/// - `cx` - the centre's column.
/// - `cy` - the centre's row.
/// - `radius` - in pixels. 0 is one pixel; less draws nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The midpoint algorithm: one eighth of it is walked with whole numbers
/// only and the other seven come from its symmetry, so there is no
/// rounding to drift and no arithmetic a small machine minds.
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
/// `DrawEllipse`, `DrawArc`, `AreaCircle`
///
/// EXAMPLES:
/// ```zig
/// gb.DrawCircle(rp, 160, 100, 40);
/// ```
pub fn DrawCircle(gb: *GraphicsBase, rp: *RastPort, cx: i32, cy: i32, radius: i32) void {
    rp.last_error = graphics.GERR_OK;
    if (radius < 0) return;
    var step: u32 = rp.pattern_step;
    var bound = Rect{};
    var any = false;

    var x: i32 = 0;
    var y: i32 = radius;
    var d: i32 = 1 - radius;
    while (x <= y) {
        circlePoints(rp, cx, cy, x, y, &step, &bound, &any);
        x += 1;
        if (d < 0) {
            d += 2 * x + 1;
        } else {
            y -= 1;
            d += 2 * (x - y) + 1;
        }
    }
    rp.pattern_step = step;
    if (any) handOn(gb, rp, bound.min_y, bound.max_y);
}
