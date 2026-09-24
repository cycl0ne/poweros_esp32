// SPDX-License-Identifier: MPL-2.0
//! WritePixel: one pixel in the foreground pen.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const handOn = _draw.handOn;
const plot = _draw.plot;
const visible = _draw.visible;
const RastPort = _draw.RastPort;
const _draw = @import("_draw.zig");

/// One pixel in the foreground pen.
///
/// SYNOPSIS:
/// ```zig
/// fn WritePixel(gb: *GraphicsBase, rp: *RastPort, x: i32, y: i32) void
/// ```
///
/// SINCE: 0.9. LVO -60.
///
/// INPUTS:
/// - `rp` - the RastPort. Its pen, draw mode and clip decide the result.
/// - `x` - the pixel's column. Outside the clip draws nothing, which is not
///   an error.
/// - `y` - its row.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The line pattern is not consulted - one pixel is not a run, and a
/// caller that asked for a pixel meant a pixel.
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
/// `ReadPixel`, `Draw`
///
/// EXAMPLES:
/// ```zig
/// gb.WritePixel(rp, 10, 10);
/// ```
pub fn WritePixel(gb: *GraphicsBase, rp: *RastPort, x: i32, y: i32) void {
    rp.last_error = graphics.GERR_OK;
    var it = visible(rp, .{ .min_x = x, .min_y = y, .max_x = x + 1, .max_y = y + 1 });
    const piece = it.next() orelse return;
    plot(rp, piece, x, y);
    handOn(gb, rp, y, y + 1);
}
