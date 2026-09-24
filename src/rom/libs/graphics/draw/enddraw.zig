// SPDX-License-Identifier: MPL-2.0
//! EndDraw: the end of a piece of work, and the rows it wrote handed on.

const std = @import("std");
const sdk = @import("sdk");
const graphics = sdk.graphics;

const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const RastPort = @import("../rastport/_rastport.zig").RastPort;
const draw = @import("_draw.zig");

/// The rows gathered since `BeginDraw` handed to the display, in one.
///
/// SYNOPSIS:
/// ```zig
/// fn EndDraw(gb: *GraphicsBase, rp: *RastPort) void
/// ```
///
/// SINCE: 1.0. LVO -280.
///
/// INPUTS:
/// - `gb` - the library's base.
/// - `rp` - the RastPort the piece of work was drawn with.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The rows written since the matching `BeginDraw` go to the display as
/// one run, from the first row written to the last - what lies between
/// them is sent as well, since a run is what a display is told. Nothing
/// was drawn, nothing is sent.
///
/// With batches nested, this closes one of them; the rows go when the
/// last one closes. Without a `BeginDraw` to match, it does nothing.
///
/// CONTEXT:
/// Waits: no. Interrupts: yes. Forbid: yes. Process: no.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// The rows go to the buffer `BeginDraw` remembered, not to whatever the
/// RastPort's clip targets point at now: a window moved or resized in
/// between rebuilds those, and the rows belong to the buffer they were
/// written into.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BeginDraw`, `rtg.RefreshBitMap`
///
/// EXAMPLES:
/// ```zig
/// gb.BeginDraw(rp);
/// defer gb.EndDraw(rp);
/// ```
pub fn EndDraw(gb: *GraphicsBase, rp: *RastPort) void {
    rp.last_error = graphics.GERR_OK;
    if (rp.draw_depth == 0) return;
    rp.draw_depth -= 1;
    const bm = rp.draw_held orelse return;
    if (rp.draw_depth == 0) rp.draw_held = null;
    // Counted and taken with nothing else running: every task drawing on
    // the buffer shares the count and the span, and a count lost to a
    // task switch would leave the buffer gathering for ever.
    const span = taken: {
        gb.sys_base.Forbid();
        defer gb.sys_base.Permit();
        if (bm.held == 0) return;
        bm.held -= 1;
        if (bm.held != 0) return;
        break :taken draw.takeSpan(bm) orelse return;
    };
    // Sent with the scheduler free again: a driver may wait on its bus.
    _ = gb.rtg_base.RefreshBitMap(bm, span.top, span.end - span.top);
}

// --- tests (host: ./zig build test) -----------------------------------------
//
// The calls are tested together in graphics.zig, where a board and a
// buffer can be made to draw into.

const testing = std.testing;

test "EndDraw without a BeginDraw does nothing" {
    var rp: RastPort = undefined;
    rp.draw_depth = 0;
    rp.draw_held = null;
    EndDraw(undefined, &rp);
    try testing.expectEqual(@as(u32, 0), rp.draw_depth);
}
