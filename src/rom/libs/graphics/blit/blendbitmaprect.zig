// SPDX-License-Identifier: MPL-2.0
//! BlendBitMapRect: lays a colour over a rectangle of a buffer by its
//! alpha.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const Rect = graphics.Rect;
const rastport = @import("../rastport/_rastport.zig");
const _lay = @import("_lay.zig");

/// Lays a colour over a rectangle of a buffer by the colour's alpha.
///
/// SYNOPSIS:
/// ```zig
/// fn BlendBitMapRect(gb: *GraphicsBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pen: graphics.Pen) i32
/// ```
///
/// SINCE: 0.52. LVO -368.
///
/// INPUTS:
/// - `dest` - the buffer: a board's, or an `RtgBitMap` of the caller's
///   own that describes plain memory and names no board.
/// - `area` - the rectangle.
/// - `pen` - the colour, 0xAARRGGBB: its alpha is how much of it lands.
///
/// RESULT:
/// `GERR_OK` - also when none of the rectangle is inside the buffer;
/// `GERR_BAD_FORMAT` for a buffer in a format without colours,
/// `GERR_BAD_SIZE` for one with no pixels. Nothing is laid then.
///
/// BEHAVIOR:
/// **The buffer has no drawing state**, as `BltBitMap`'s sides have
/// none: the rectangle is cut to the buffer, and nothing is handed on to
/// a display - the caller does that (`rtg.RefreshRect`).
///
/// Every pixel of the rectangle is mixed with the colour by the colour's
/// alpha, as `RectFill` lays a pen under `DRMD_BLEND`: none of it for an
/// alpha of 0, the colour itself for 255, and black at an alpha is a
/// shade.
///
/// Where `dest` is a board's and the board has an engine that takes the
/// job, the engine lays it (`rtg.BlendRect`). Otherwise the rows are cut
/// into bands and every core lays its share at once; a rectangle of few
/// pixels is laid by the caller alone.
///
/// CONTEXT:
/// - Waits: for exec's workers, where the rows are shared; for the
///   board's engine, where it takes the job.
/// - Interrupts: no. The work is unbounded.
/// - Locks: none taken. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BlendBitMapPixels`, `BltBitMapRects`, `RectFill`
///
/// EXAMPLES:
/// ```zig
/// // What is there, a third darker.
/// _ = gb.BlendBitMapRect(display, &.{ .x = 0, .y = 0, .width = 640, .height = 480 }, 0x5500_0000);
/// ```
pub fn BlendBitMapRect(gb: *GraphicsBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pen: graphics.Pen) i32 {
    if (dest.pixels == null) return graphics.GERR_BAD_SIZE;
    if (rastport.packPen(dest.format, 0) == null) return graphics.GERR_BAD_FORMAT;
    if (dest.board != null and gb.rtg_base.BlendRect(dest, area, pen) == rtg.errors.RTGERR_OK) return graphics.GERR_OK;
    if (area.width <= 0 or area.height <= 0) return graphics.GERR_OK;
    // Wide, so that a rectangle near the end of the numbers cannot wrap.
    const left = @max(@as(i64, area.x), 0);
    const top = @max(@as(i64, area.y), 0);
    const right = @min(@as(i64, area.x) + area.width, @as(i64, dest.width));
    const bottom = @min(@as(i64, area.y) + area.height, @as(i64, dest.height));
    if (right <= left or bottom <= top) return graphics.GERR_OK;
    _lay.tint(gb, @ptrCast(dest), .{ .min_x = @intCast(left), .min_y = @intCast(top), .max_x = @intCast(right), .max_y = @intCast(bottom) }, pen);
    return graphics.GERR_OK;
}
