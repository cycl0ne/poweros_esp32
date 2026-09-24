// SPDX-License-Identifier: MPL-2.0
//! What the drawing calls share: a chain of IntuiText runs put down.
//!
//! `PrintIText` draws each run in its own pens and draw mode; an itexticlass
//! image draws its runs in the one pen the image has, so a label takes its
//! colour from where it is shown. Both are this loop, told which.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const TagItem = utility.TagItem;
const IntuiText = sdk.intuition.IntuiText;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const d = @import("../classes/draw.zig");

/// Each run of the chain at (left, top) plus its own place, in its font when
/// it names one. `ink` null draws each in its own pens and draw mode; a pen
/// draws every run in that pen, in JAM1. The RastPort gets its pens, mode
/// and font back; its current point is left where the last run ended.
pub fn printRuns(ib: *IntuitionBase, rp: *graphics.RastPort, itext: ?*const IntuiText, left: i32, top: i32, ink: ?graphics.Pen) void {
    const gb = ib.graphics_base;
    const ub = ib.utility_base;
    const saved = d.save(gb, rp);
    defer d.restore(gb, rp, saved);
    if (ink) |pen| d.pen(gb, rp, pen);

    var at = itext;
    while (at) |run| : (at = run.next) {
        const words = run.text orelse continue;
        const count: u32 = @intCast(ub.Strlen(words));
        if (count == 0) continue;
        var tags = [_]TagItem{
            .{ .tag = graphics.RPTAG_APen, .data = run.front_pen },
            .{ .tag = graphics.RPTAG_BPen, .data = run.back_pen },
            .{ .tag = graphics.RPTAG_DrMd, .data = run.draw_mode },
            .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(run.font) },
            .{},
        };
        // The one pen given wins over the runs' own.
        if (ink != null) {
            tags[0] = .{ .tag = utility.TAG_IGNORE, .data = 0 };
            tags[1] = .{ .tag = utility.TAG_IGNORE, .data = 0 };
            tags[2] = .{ .tag = utility.TAG_IGNORE, .data = 0 };
        }
        // A run that names no font keeps the RastPort's own.
        if (run.font == null) tags[3] = .{ .tag = utility.TAG_IGNORE, .data = 0 };
        gb.SetRPAttrs(rp, &tags);
        // The font is known only now, so its baseline is asked for here.
        var baseline: u32 = 0;
        const metric = [_]TagItem{
            .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
            .{},
        };
        gb.GetRPAttrs(rp, &metric);
        gb.Move(rp, left + run.left, top + run.top + @as(i32, @intCast(baseline)));
        gb.Text(rp, words, count);
    }
}
