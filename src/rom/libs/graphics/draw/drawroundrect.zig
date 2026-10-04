// SPDX-License-Identifier: MPL-2.0
//! DrawRoundRect: the outline of a rectangle whose corners are rounded.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _draw = @import("_draw.zig");
const _round = @import("_round.zig");
const handOn = _draw.handOn;
const pieceAt = _draw.pieceAt;
const plotPatterned = _draw.plotPatterned;
const grow = _draw.grow;
const Rect = graphics.Rect;
const RastPort = _draw.RastPort;

/// The outline of a rectangle whose corners are rounded.
///
/// SYNOPSIS:
/// ```zig
/// fn DrawRoundRect(gb: *GraphicsBase, rp: *RastPort, area: *const Rect,
///     radius: u32) void
/// ```
///
/// SINCE: 0.21. LVO -320.
///
/// INPUTS:
/// - `rp` - the RastPort. Its pen, its line pattern, its draw mode and
///   its clip decide the result.
/// - `area` - the rectangle the outline sits in, half-open: the line is
///   drawn on the rows `min_y` and `max_y - 1` and the columns `min_x`
///   and `max_x - 1`.
/// - `radius` - how far the corners are rounded. 0 is `DrawRect`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Four straight edges, shortened by the radius at each end, and a
/// quarter circle in each corner. The corners come off the same table of
/// insets `FillRoundRect` fills from, so an outline drawn round a fill of
/// the same radius and rectangle meets it exactly with no gap and no
/// doubled line.
///
/// A `radius` larger than half the shorter side is taken down to it, and
/// to 256 in any case.
///
/// The line pattern runs along the straight edges and round the corners
/// as one walk, so a dashed outline keeps its rhythm through a corner.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated; the corner's table is on the stack.
///
/// NOTES:
/// A radius of 1 rounds by a single pixel at each corner, which is what a
/// frame that should not look sharp usually wants.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FillRoundRect`, `DrawRect`, `RPTAG_LinePattern`
///
/// EXAMPLES:
/// ```zig
/// // A field, drawn round a fill of the same shape.
/// const box = graphics.Rect{ .min_x = 8, .min_y = 8, .max_x = 160, .max_y = 34 };
/// gb.FillRoundRect(rp, &box, 6);
/// gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = ink }, .{} });
/// gb.DrawRoundRect(rp, &box, 6);
/// ```
pub fn DrawRoundRect(gb: *GraphicsBase, rp: *RastPort, area: *const Rect, radius: u32) void {
    const graphics_lib = gb.iface();
    rp.last_error = graphics.GERR_OK;
    if (area.isEmpty()) return;

    if (rp.line_width > 1 or (rp.smooth and radius > 0)) return @import("_wide.zig").roundRect(gb, rp, area.*, radius, @intCast(rp.line_width), null);
    const r = @min(_round.fits(area.*, radius), _round.radius_max);
    if (r <= 0) {
        graphics_lib.DrawRect(@ptrCast(rp), area);
        return;
    }

    // The straight parts, each shortened by a corner at both ends.
    const across = area.width() - 2 * r;
    const down = area.height() - 2 * r;
    if (across > 0) {
        graphics_lib.DrawHLine(@ptrCast(rp), area.min_x + r, area.min_y, across);
        graphics_lib.DrawHLine(@ptrCast(rp), area.min_x + r, area.max_y - 1, across);
    }
    if (down > 0) {
        graphics_lib.DrawVLine(@ptrCast(rp), area.min_x, area.min_y + r, down);
        graphics_lib.DrawVLine(@ptrCast(rp), area.max_x - 1, area.min_y + r, down);
    }

    var table: [_round.radius_max]i32 = undefined;
    _round.insets(r, table[0..@intCast(r)]);

    // The corners. A row of the corner is one pixel of the outline where
    // the inset changed from the row above, and a short run where it
    // jumped several - the run is what keeps a flat-topped corner joined
    // instead of dotted.
    var bound = Rect{};
    var any = false;
    var step: u32 = 0;
    var i: i32 = 0;
    while (i < r) : (i += 1) {
        const inset = table[@intCast(i)];
        const before = if (i == 0) r else table[@intCast(i - 1)];
        var x = inset;
        while (x < before) : (x += 1) {
            const corners = [_][2]i32{
                .{ area.min_x + x, area.min_y + i },
                .{ area.max_x - 1 - x, area.min_y + i },
                .{ area.min_x + x, area.max_y - 1 - i },
                .{ area.max_x - 1 - x, area.max_y - 1 - i },
            };
            for (corners) |at| {
                const piece = pieceAt(rp, at[0], at[1]) orelse continue;
                plotPatterned(rp, piece, at[0], at[1], step);
                step +%= 1;
                grow(&bound, at[1], &any);
            }
        }
    }
    if (any) handOn(gb, rp, bound.min_y, bound.max_y);
}
