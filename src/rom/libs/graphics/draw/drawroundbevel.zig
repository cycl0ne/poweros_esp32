// SPDX-License-Identifier: MPL-2.0
//! DrawRoundBevel: a rounded rectangle's outline as a bevel, in two
//! colours.
//!
//! The outline is the ring a wide `DrawRoundRect` draws, and each pixel of
//! it is the light colour's or the dark's by which of the box's edges it
//! is nearer (`_smooth.Side`): the ring is drawn twice, once a side.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _draw = @import("_draw.zig");
const _smooth = @import("_smooth.zig");
const _wide = @import("_wide.zig");
const Rect = graphics.Rect;
const Pen = graphics.Pen;
const RastPort = _draw.RastPort;
const TagItem = sdk.utility.TagItem;

/// Draws the outline of a rectangle whose corners are rounded as a bevel:
/// one colour on the top and the left, another on the bottom and the
/// right.
///
/// SYNOPSIS:
/// ```zig
/// fn DrawRoundBevel(gb: *GraphicsBase, rp: *RastPort, area: *const Rect,
///     radius: u32, light: Pen, dark: Pen) void
/// ```
///
/// SINCE: 0.25. LVO -340.
///
/// INPUTS:
/// - `rp` - the RastPort. Its line width, its smooth edges, its draw mode
///   and its clip decide the result; its pen is left as it was.
/// - `area` - the rectangle the outline sits in, half-open.
/// - `radius` - how far the corners are rounded. 0 is a square bevel.
/// - `light` - the colour of the top and the left: the shine of a raised
///   bevel, the shadow of a recessed one.
/// - `dark` - the colour of the bottom and the right.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The outline is the one `DrawRoundRect` draws with the same line width:
/// `RPTAG_LineWidth` thick, growing inward, its inner edge the same shape
/// with a radius that much smaller, with smooth edges under
/// `RPTAG_Smooth`.
///
/// A pixel of it is light when it is nearer the top or the left edge than
/// the bottom or the right one, and dark otherwise. The two colours meet
/// on the diagonal through the top-right and the bottom-left corner, which
/// runs through the middle of a rounded corner's quarter circle - where a
/// square bevel's angled joins meet too - however long or short the box
/// is. The change is hard: each pixel is wholly one colour, decided at its
/// middle. A pixel exactly on the diagonal is light in the box's left half
/// and dark in its right one, so the two corners mirror each other.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not wanted.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// - The line pattern is not used: a bevel is solid.
/// - A ridge or a groove is two of these, the inner one in the box the
///   outer one leaves, with its colours the other way round.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DrawRoundRect`, `FillRoundRect`, `RPTAG_LineWidth`, `RPTAG_Smooth`
///
/// EXAMPLES:
/// ```zig
/// // A raised button two pixels deep with rounded corners.
/// gb.SetRPAttrs(rp, &[_]TagItem{
///     .{ .tag = graphics.RPTAG_LineWidth, .data = 2 },
///     .{ .tag = graphics.RPTAG_Smooth, .data = 1 },
///     .{},
/// });
/// gb.DrawRoundBevel(rp, &box, 6, shine, shadow);
/// ```
pub fn DrawRoundBevel(gb: *GraphicsBase, rp: *RastPort, area: *const Rect, radius: u32, light: Pen, dark: Pen) void {
    const graphics_lib = gb.iface();
    rp.last_error = graphics.GERR_OK;
    if (area.isEmpty()) return;
    const pen = rp.fg_pen;
    const width: i32 = @max(@as(i32, @intCast(rp.line_width)), 1);
    for ([_]bool{ true, false }) |is_light| {
        graphics_lib.SetRPAttrs(@ptrCast(rp), &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = if (is_light) light else dark }, .{} });
        _wide.roundRect(gb, rp, area.*, radius, width, .{ .box = area.*, .light = is_light });
    }
    graphics_lib.SetRPAttrs(@ptrCast(rp), &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = pen }, .{} });
}
