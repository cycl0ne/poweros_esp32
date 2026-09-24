// SPDX-License-Identifier: MPL-2.0
//! RectFill: fills a rectangle with the RastPort's pen.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const handOn = _draw.handOn;
const fillSoftware = _draw.fillSoftware;
const fillByEngine = _draw.fillByEngine;
const visible = _draw.visible;
const Rect = graphics.Rect;
const RastPort = _draw.RastPort;
const _draw = @import("_draw.zig");

/// Fills a rectangle with the RastPort's pen.
///
/// SYNOPSIS:
/// ```zig
/// fn RectFill(gb: *GraphicsBase, rp: *RastPort, area: *const Rect) void
/// ```
///
/// SINCE: 0.3. LVO -28.
///
/// INPUTS:
/// - `rp` - the RastPort. Its pen, its draw mode and its clip are what
///   decide the result.
/// - `area` - what to fill, in the surface's coordinates, half-open: the
///   row `max_y` and the column `max_x` are not written. It may lie partly
///   or wholly outside the surface.
///
/// RESULT:
/// Nothing. There is no way for it to fail: a rectangle outside the clip
/// draws nothing, which is an answer and not an error, and a pen that
/// could not be packed was refused when the RastPort was made.
///
/// BEHAVIOR:
/// The rectangle is clipped to the RastPort's clip, which is itself inside
/// the surface, and what is left is filled. The pen's alpha decides how:
///
/// - **Opaque** (`AA` = `0xFF`) and the surface is a board's buffer: the
///   board's engine is asked to do it. An engine it has not got, or one
///   that will not take this format, answers RTGERR_NOT_SUPPORTED and it
///   falls to software - which is what both of this machine's displays do
///   today.
/// - **Anything less**, or plain memory: composed here, a pixel at a time,
///   reading what is under it. A board's engine takes one colour word and
///   has nowhere to put a coverage, so this cannot be given to it.
///
/// `DRMD_JAM1` alone writes the pen whatever its alpha, so a pen that is not
/// opaque is only composed under `.src_over`.
///
/// The rows that were written are handed on to the display before it
/// returns, so drawing is immediate. Only the rows
/// touched go: a small fill costs a small refresh. A surface in plain
/// memory has nobody to hand them to.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. The work is unbounded - a full-screen fill is a
///   million pixels - and it hands rows on to rtg.library at the end.
/// - Forbid: not held and not wanted.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The surface is written and nothing else is
/// touched.
///
/// NOTES:
/// - The rectangle is half-open, as every rectangle here is: `max_x` is
///   one past the last pixel. Filling 0,0 to 8,4 writes 32 pixels.
/// - Every drawing call takes the same path through the clip, which today
///   hands back one rectangle and will hand back a region's several. A
///   caller never sees the difference.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateRastPortTagList`, `rtg.FillRect`, `rtg.RefreshBitMap`
///
/// EXAMPLES:
/// ```zig
/// // A red box on the display.
/// const tags = [_]TagItem{
///     .{ .tag = sdk.graphics.RPTAG_APen, .data = sdk.graphics.penRGB(255, 0, 0) },
///     .{},
/// };
/// const rp = gb.CreateRastPortTagList(&tags) orelse return;
/// defer gb.FreeRastPort(rp);
/// gb.RectFill(rp, &.{ .min_x = 10, .min_y = 10, .max_x = 110, .max_y = 60 });
///
/// // Half-covering green over it, which is composed rather than written.
/// const shade = [_]TagItem{
///     .{ .tag = sdk.graphics.RPTAG_APen, .data = sdk.graphics.penARGB(128, 0, 255, 0) },
///     .{ .tag = sdk.graphics.RPTAG_DrMd, .data = sdk.graphics.DRMD_BLEND },
///     .{},
/// };
/// const over = gb.CreateRastPortTagList(&shade) orelse return;
/// defer gb.FreeRastPort(over);
/// gb.RectFill(over, &.{ .min_x = 60, .min_y = 10, .max_x = 160, .max_y = 60 });
/// ```
pub fn RectFill(gb: *GraphicsBase, rp: *RastPort, area: *const Rect) void {
    // It cannot fail. It says so anyway, so that what is read belongs to
    // the call just made rather than to one five calls ago.
    rp.last_error = graphics.GERR_OK;
    var it = visible(rp, area.*);
    var top: i32 = 0;
    var end: i32 = 0;
    var any = false;

    while (it.next()) |r| {
        if (!fillByEngine(gb, rp, r)) fillSoftware(rp, r);
        if (!any) {
            top = r.rect.min_y;
            end = r.rect.max_y;
            any = true;
        } else {
            top = @min(top, r.rect.min_y);
            end = @max(end, r.rect.max_y);
        }
    }
    if (any) handOn(gb, rp, top, end);
}
