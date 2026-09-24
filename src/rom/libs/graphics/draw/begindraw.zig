// SPDX-License-Identifier: MPL-2.0
//! BeginDraw: the drawing that follows is one piece of work.

const std = @import("std");
const sdk = @import("sdk");
const graphics = sdk.graphics;

const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const RastPort = @import("../rastport/_rastport.zig").RastPort;

/// The drawing from here to the matching `EndDraw` is one piece of work.
///
/// SYNOPSIS:
/// ```zig
/// fn BeginDraw(gb: *GraphicsBase, rp: *RastPort) void
/// ```
///
/// SINCE: 1.0. LVO -276.
///
/// INPUTS:
/// - `gb` - the library's base.
/// - `rp` - the RastPort the piece of work is drawn with.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Every drawing call hands the rows it wrote to the display as it
/// finishes, so a thing drawn in two calls - rubbed out, then drawn
/// again - can be seen half done: the display is given the picture
/// between the two. Between `BeginDraw` and `EndDraw` the rows are
/// gathered instead, and `EndDraw` hands the lot on at once, so no
/// half-finished state is ever shown.
///
/// The batch is held on the **buffer**, not on this RastPort, so drawing
/// through another RastPort onto the same buffer is gathered into it
/// too. That is what lets whoever manages windows open one around a
/// window's whole redraw while the drawing itself goes through a
/// RastPort of its own.
///
/// They nest. Each `BeginDraw` needs its own `EndDraw`, and nothing is
/// handed on until the last.
///
/// A RastPort drawing into plain memory has nothing to hand rows to, and
/// this does nothing for it.
///
/// CONTEXT:
/// Waits: no. Interrupts: yes. Forbid: yes. Process: no.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// None.
///
/// BUGS:
/// A `BeginDraw` whose `EndDraw` never comes leaves the buffer gathering
/// for ever and nothing more reaches the display from it, as a `Forbid`
/// with no `Permit` stops the machine scheduling. Pair them on every
/// path out, an error return included.
///
/// SEE ALSO:
/// `EndDraw`, `rtg.RefreshBitMap`
///
/// EXAMPLES:
/// ```zig
/// gb.BeginDraw(rp);
/// gb.WritePixelArray(rp, ...); // the old pointer rubbed out
/// gb.WritePixelArray(rp, ...); // the new one drawn
/// gb.EndDraw(rp); // both reach the display together
/// ```
pub fn BeginDraw(gb: *GraphicsBase, rp: *RastPort) void {
    rp.last_error = graphics.GERR_OK;
    if (rp.draw_depth == 0) {
        // The buffer this RastPort writes to: the first target that has
        // one, or its own. Remembered, so the matching EndDraw releases
        // this buffer whatever the clip targets say by then.
        rp.draw_held = null;
        if (rp.clip_list) |list| {
            var at = list;
            while (true) {
                if (at.bitmap) |bm| {
                    rp.draw_held = bm;
                    break;
                }
                at = at.next orelse break;
            }
        } else {
            rp.draw_held = rp.bitmap;
        }
    }
    const bm = rp.draw_held orelse return;
    rp.draw_depth += 1;
    // Every task drawing on the buffer counts here, so the count is
    // raised with nothing else running.
    gb.sys_base.Forbid();
    defer gb.sys_base.Permit();
    bm.held += 1;
}

// --- tests (host: ./zig build test) -----------------------------------------
//
// The calls are tested together in graphics.zig, where a board and a
// buffer can be made to draw into.

const testing = std.testing;

test "BeginDraw on a RastPort with no buffer does nothing" {
    var rp: RastPort = undefined;
    rp.clip_list = null;
    rp.bitmap = null;
    rp.draw_depth = 0;
    rp.draw_held = null;
    BeginDraw(undefined, &rp);
    try testing.expectEqual(@as(u32, 0), rp.draw_depth);
    try testing.expectEqual(@as(?*sdk.rtg.RtgBitMap, null), rp.draw_held);
}
