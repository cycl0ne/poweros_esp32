// SPDX-License-Identifier: MPL-2.0
//! DrawBorder: draws the line through each Border's points, each in its
//! own pens and draw mode, and gives the RastPort back with its own.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const TagItem = utility.TagItem;
const Border = sdk.intuition.Border;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const d = @import("../classes/draw.zig");

/// Draws a Border and the Borders linked after it.
///
/// SYNOPSIS:
/// ```zig
/// fn DrawBorder(ib: *IntuitionBase, rp: *graphics.RastPort,
///     border: ?*const Border, left: i32, top: i32) void
/// ```
///
/// SINCE: 0.9. LVO -212.
///
/// INPUTS:
/// - `rp` - where to draw.
/// - `border` - the first Border, or null, which draws nothing.
/// - `left`, `top` - added to each Border's own `left` and `top`, which
///   are added to each of its points.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Each Border in turn: its front and back pen and its draw mode are set,
/// and a line is drawn from its first point to its second, on to its
/// third, and so on through all `count` of them - both ends of every
/// stretch, as graphics' `Draw` draws them. The RastPort's line pattern is
/// the caller's and is used as it is. A Border with no points, or only
/// one, draws nothing.
///
/// CONTEXT:
/// - Waits: no, beyond what the RastPort's layer asks of a caller - hold
///   it, as for any drawing in a window.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands. The RastPort gets its pens, draw mode and
/// current point back as they were.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `PrintIText`, `DrawImage`, graphics' `Draw`
///
/// EXAMPLES:
/// ```zig
/// // A 40x10 box, closed on its first corner.
/// const corners = [_]i32{ 0, 0, 39, 0, 39, 9, 0, 9, 0, 0 };
/// const box = intuition.Border{
///     .front_pen = graphics.penRGB(0, 0, 0),
///     .count = corners.len / 2,
///     .xy = &corners,
/// };
/// ib.DrawBorder(rp, &box, 10, 20);
/// ```
pub fn DrawBorder(ib: *IntuitionBase, rp: *graphics.RastPort, border: ?*const Border, left: i32, top: i32) void {
    const gb = ib.graphics_base;
    const saved = d.save(gb, rp);
    defer d.restore(gb, rp, saved);
    var cursor: graphics.Point = .{};
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_Cursor, .data = @intFromPtr(&cursor) }, .{} };
    gb.GetRPAttrs(rp, &ask);
    defer gb.Move(rp, cursor.x, cursor.y);

    var at = border;
    while (at) |line| : (at = line.next) {
        const xy = line.xy orelse continue;
        if (line.count < 2) continue;
        const tags = [_]TagItem{
            .{ .tag = graphics.RPTAG_APen, .data = line.front_pen },
            .{ .tag = graphics.RPTAG_BPen, .data = line.back_pen },
            .{ .tag = graphics.RPTAG_DrMd, .data = line.draw_mode },
            .{},
        };
        gb.SetRPAttrs(rp, &tags);
        const x = left + line.left;
        const y = top + line.top;
        gb.Move(rp, x + xy[0], y + xy[1]);
        var point: u32 = 1;
        while (point < line.count) : (point += 1) {
            gb.Draw(rp, x + xy[2 * point], y + xy[2 * point + 1]);
        }
    }
}
