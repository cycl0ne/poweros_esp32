// SPDX-License-Identifier: MPL-2.0
//! FillRoundRect: fills a rectangle whose corners are rounded.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _draw = @import("_draw.zig");
const _round = @import("_round.zig");
const fillSpan = _draw.fillSpan;
const handOn = _draw.handOn;
const Rect = graphics.Rect;
const RastPort = _draw.RastPort;

/// Fills a rectangle whose corners are rounded, with the RastPort's pen.
///
/// SYNOPSIS:
/// ```zig
/// fn FillRoundRect(gb: *GraphicsBase, rp: *RastPort, area: *const Rect,
///     radius: u32) void
/// ```
///
/// SINCE: 0.21. LVO -316.
///
/// INPUTS:
/// - `rp` - the RastPort. Its pen, its draw mode and its clip decide the
///   result, exactly as for `RectFill`.
/// - `area` - what to fill, half-open: the row `max_y` and the column
///   `max_x` are not written. It may lie partly or wholly outside the
///   surface.
/// - `radius` - how far the corners are rounded. 0 fills the rectangle
///   itself.
///
/// RESULT:
/// Nothing. A rectangle outside the clip draws nothing, which is an
/// answer and not an error.
///
/// BEHAVIOR:
/// The middle of the shape is filled row by row, each row as wide as the
/// corners leave it: the full width between the corners, and less at the
/// top and bottom where a corner cuts in. Every row goes through the same
/// span fill the area calls use, so the clip, the pen's alpha and the
/// draw mode all behave as they do everywhere else.
///
/// A `radius` larger than half the shorter side is taken down to it. A
/// square filled that way is a disc and a long box is a stadium, which is
/// what asking for a radius that large means. A radius is also taken down
/// to 256, which on either of this machine's displays is already a corner
/// half the height of the screen.
///
/// The rows that were written are handed on to the display before it
/// returns, so drawing is immediate.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. The work is unbounded and it hands rows on to
///   rtg.library at the end.
/// - Forbid: not held and not wanted.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated: the corner's shape is worked out into a table on
/// the stack. The surface is written and nothing else is touched.
///
/// NOTES:
/// - The corners are hard-edged, as every shape here is. What makes them
///   smooth is coverage on a shape's edge, which is a change inside the
///   span fill rather than in this call.
/// - The fill and `DrawRoundRect`'s outline are worked out from one
///   table, so an outline drawn round a fill of the same radius meets it
///   exactly.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DrawRoundRect`, `RectFill`, `FillArc`
///
/// EXAMPLES:
/// ```zig
/// // The body of a button.
/// gb.FillRoundRect(rp, &.{ .min_x = 10, .min_y = 10, .max_x = 130, .max_y = 42 }, 8);
/// ```
pub fn FillRoundRect(gb: *GraphicsBase, rp: *RastPort, area: *const Rect, radius: u32) void {
    rp.last_error = graphics.GERR_OK;
    if (area.isEmpty()) return;

    const r = @min(_round.fits(area.*, radius), _round.radius_max);
    var bound = Rect{};
    var any = false;

    if (r <= 0) {
        var y = area.min_y;
        while (y < area.max_y) : (y += 1) fillSpan(rp, area.min_x, area.max_x, y, &bound, &any);
        if (any) handOn(gb, rp, bound.min_y, bound.max_y);
        return;
    }

    var table: [_round.radius_max]i32 = undefined;
    _round.insets(r, table[0..@intCast(r)]);

    // The corners, a row of each at a time: the top row of the shape and
    // the bottom row take the same inset, so both ends are walked
    // together and the middle is left whole.
    var i: i32 = 0;
    while (i < r) : (i += 1) {
        const inset = table[@intCast(i)];
        const left = area.min_x + inset;
        const right = area.max_x - inset;
        fillSpan(rp, left, right, area.min_y + i, &bound, &any);
        fillSpan(rp, left, right, area.max_y - 1 - i, &bound, &any);
    }

    // What the corners left: every row between them, full width.
    var y = area.min_y + r;
    while (y < area.max_y - r) : (y += 1) fillSpan(rp, area.min_x, area.max_x, y, &bound, &any);

    if (any) handOn(gb, rp, bound.min_y, bound.max_y);
}
