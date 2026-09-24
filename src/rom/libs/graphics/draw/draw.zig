// SPDX-License-Identifier: MPL-2.0
//! Draw: draws a line from the current point, which then moves to the end of it.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const handOn = _draw.handOn;
const line = _draw.line;
const clipSegment = _draw.clipSegment;
const visible = _draw.visible;
const RastPort = _draw.RastPort;
const _draw = @import("_draw.zig");

/// Draws a line from the current point, which then moves to the end of it.
///
/// SYNOPSIS:
/// ```zig
/// fn Draw(gb: *GraphicsBase, rp: *RastPort, x: i32, y: i32) void
/// ```
///
/// SINCE: 0.6. LVO -56.
///
/// INPUTS:
/// - `rp` - the RastPort, whose pen, draw mode and clip decide the result.
/// - `x`, `y` - where the line ends. Either end may be outside the
///   surface.
///
/// RESULT:
/// Nothing. A line entirely outside the clip draws nothing, which is an
/// answer and not an error.
///
/// BEHAVIOR:
/// Both ends are drawn, so a Move followed by a Draw to the same place puts
/// down one pixel.
///
/// **The current point moves whether or not anything was drawn.** It is
/// where the next Draw starts from, not where the last one reached, so a
/// run of Draws traces the shape that was asked for even while part of it
/// is off the surface.
///
/// The line is cut to the clip before any of it is walked, rather than
/// walked with every pixel tested - so a line mostly off the surface costs
/// almost nothing, which is what a window dragged half off the screen will
/// ask for constantly.
///
/// There is no engine call: a board's engine fills and copies rectangles,
/// and this is neither. A pen that is not opaque composes under
/// `.src_over`, as everywhere else.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. The work is unbounded and it hands rows on at the end.
/// - Forbid: not held and not wanted.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// - The rows written are handed on to the display before it returns, as
///   every drawing call does. A run of Draws therefore costs a refresh
///   each; that is the same bargain RectFill makes, and the place to
///   change it if it is ever measured to matter is `handOn`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Move`, `RectFill`
///
/// EXAMPLES:
/// ```zig
/// // A box, drawn as four lines.
/// gb.Move(rp, 10, 10);
/// gb.Draw(rp, 100, 10);
/// gb.Draw(rp, 100, 60);
/// gb.Draw(rp, 10, 60);
/// gb.Draw(rp, 10, 10);
/// ```
pub fn Draw(gb: *GraphicsBase, rp: *RastPort, x: i32, y: i32) void {
    rp.last_error = graphics.GERR_OK;
    const from_x = rp.cp_x;
    const from_y = rp.cp_y;
    // The current point moves whether or not any of the line was visible:
    // it is where the next Draw starts from, not where the last one drew.
    rp.cp_x = x;
    rp.cp_y = y;

    var step: u32 = rp.pattern_step;
    var it = visible(rp, .{
        .min_x = @min(from_x, x),
        .min_y = @min(from_y, y),
        .max_x = @max(from_x, x) + 1,
        .max_y = @max(from_y, y) + 1,
    });
    var top: i32 = 0;
    var end: i32 = 0;
    var any = false;
    while (it.next()) |r| {
        const seg = clipSegment(r.rect, from_x, from_y, x, y) orelse continue;
        line(rp, r, seg[0], seg[1], seg[2], seg[3], &step);
        const lo = @min(seg[1], seg[3]);
        const hi = @max(seg[1], seg[3]) + 1;
        if (!any) {
            top = lo;
            end = hi;
            any = true;
        } else {
            top = @min(top, lo);
            end = @max(end, hi);
        }
    }
    rp.pattern_step = step;
    if (any) handOn(gb, rp, top, end);
}
