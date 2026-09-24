// SPDX-License-Identifier: MPL-2.0
//! DrawPoly: a line through each of a list of points.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const _draw = @import("_draw.zig");
const RastPort = rastport.RastPort;

/// A line through each of a list of points.
///
/// SYNOPSIS:
/// ```zig
/// fn DrawPoly(gb: *GraphicsBase, rp: *RastPort, count: u32, points: [*]const graphics.Point) void
/// ```
///
/// SINCE: 0.9. LVO -92.
///
/// INPUTS:
/// - `rp` - the RastPort. Its pen, draw mode, line pattern and clip decide
///   the result, and its current point is where the first leg starts.
/// - `count` - how many points.
/// - `points` - where to go, in turn. A closed shape repeats its first point
///   at the end.
///
/// RESULT:
/// Nothing. The current point is left at the last point.
///
/// BEHAVIOR:
/// Each leg is an ordinary `Draw`, so the current point follows it, the
/// clipping is the same clipping, and the line pattern runs on round the
/// corners rather than starting again at each.
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
/// `Draw`, `Move`, `AreaDraw`
///
/// EXAMPLES:
/// ```zig
/// const corners = [_]graphics.Point{ .{ .x = 60, .y = 10 }, .{ .x = 60, .y = 60 }, .{ .x = 10, .y = 10 } };
/// gb.Move(rp, 10, 10);
/// gb.DrawPoly(rp, corners.len, &corners);
/// ```
pub fn DrawPoly(gb: *GraphicsBase, rp: *RastPort, count: u32, points: [*]const graphics.Point) void {
    const graphics_lib = gb.iface();
    rp.last_error = graphics.GERR_OK;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // Each leg is an ordinary Draw, so the pattern runs on round the
        // corners and the clipping is the same clipping.
        graphics_lib.Draw(@ptrCast(rp), points[i].x, points[i].y);
    }
}
