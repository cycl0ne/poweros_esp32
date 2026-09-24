// SPDX-License-Identifier: MPL-2.0
//! DrawArc: part of a circle's outline.

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
const over = _draw.over;
const plotPatterned = _draw.plotPatterned;
const pieceAt = _draw.pieceAt;
const grow = _draw.grow;
const inSweep = _draw.inSweep;
const handOn = _draw.handOn;

/// Part of a circle's outline.
///
/// SYNOPSIS:
/// ```zig
/// fn DrawArc(gb: *GraphicsBase, rp: *RastPort, cx: i32, cy: i32, radius: i32, from: i32, to: i32) void
/// ```
///
/// SINCE: 0.9. LVO -88.
///
/// INPUTS:
/// - `rp` - the RastPort. Its pen, draw mode, line pattern and clip decide
///   the result.
/// - `cx` - the centre's column.
/// - `cy` - the centre's row.
/// - `radius` - in pixels; below 0 draws nothing.
/// - `from` - where the arc starts, in degrees, with 0 to the right and 90
///   upward.
/// - `to` - where it ends, the way the numbers increase. Equal to `from`
///   draws nothing; `DrawCircle` draws all of it.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The circle is walked as usual and each point is asked whether it lies in
/// the sweep. That question is answered with two cross products against
/// the sweep's edges, so no angle is ever computed for a point - the only
/// trigonometry is the two edges, and it comes from a table of a quarter
/// turn the compiler worked out. Nothing here needs floating point at run
/// time.
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
/// `DrawCircle`, `AreaArc`
///
/// EXAMPLES:
/// ```zig
/// gb.DrawArc(rp, 160, 100, 40, 0, 90); // the upper right quarter
/// ```
pub fn DrawArc(gb: *GraphicsBase, rp: *RastPort, cx: i32, cy: i32, radius: i32, from: i32, to: i32) void {
    rp.last_error = graphics.GERR_OK;
    if (radius < 0) return;
    var step: u32 = rp.pattern_step;
    var bound = Rect{};
    var any = false;

    var x: i32 = 0;
    var y: i32 = radius;
    var d: i32 = 1 - radius;
    while (x <= y) {
        const at = [_][2]i32{
            .{ x, y }, .{ -x, y }, .{ x, -y }, .{ -x, -y },
            .{ y, x }, .{ -y, x }, .{ y, -x }, .{ -y, -x },
        };
        for (at) |offset| {
            // Screen y grows downward, so the point is turned over before
            // its angle is judged - an arc from 0 to 90 then sweeps the way
            // a person expects rather than the way the memory is laid out.
            if (!inSweep(offset[0], -offset[1], from, to)) continue;
            const px = cx + offset[0];
            const py = cy + offset[1];
            const piece = pieceAt(rp, px, py) orelse continue;
            plotPatterned(rp, piece, px, py, step);
            step +%= 1;
            grow(&bound, py, &any);
        }
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
