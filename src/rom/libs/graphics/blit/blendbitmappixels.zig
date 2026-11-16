// SPDX-License-Identifier: MPL-2.0
//! BlendBitMapPixels: lays pixels of one's own over a rectangle of a
//! buffer by their coverage, at a strength.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const Rect = graphics.Rect;
const rastport = @import("../rastport/_rastport.zig");
const _lay = @import("_lay.zig");

/// Lays pixels of the caller's own over a rectangle of a buffer, each by
/// its coverage, at a strength.
///
/// SYNOPSIS:
/// ```zig
/// fn BlendBitMapPixels(gb: *GraphicsBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, alpha: u32) i32
/// ```
///
/// SINCE: 0.52. LVO -364.
///
/// INPUTS:
/// - `dest` - the buffer: a board's, or an `RtgBitMap` of the caller's
///   own that describes plain memory and names no board.
/// - `area` - the rectangle.
/// - `pixels` - the picture: its first byte, pitch and format, and the
///   pixel that lands on the rectangle's top left corner. The rectangle's
///   size is how much of it is read. A pitch of 0 lays its one row over
///   every row of the rectangle.
/// - `alpha` - 0 to 255, the strength: multiplied into every pixel's
///   coverage; 255 leaves the coverage as it is, 0 lays nothing.
///
/// RESULT:
/// `GERR_OK` - also when none of the rectangle is inside the buffer;
/// `GERR_BAD_FORMAT` for a format without colours on either side,
/// `GERR_BAD_SIZE` for a side with no pixels or a picture's corner below
/// 0. Nothing is laid then.
///
/// BEHAVIOR:
/// **The buffer has no drawing state**, as `BltBitMap`'s sides have
/// none: the rectangle is cut to the buffer, the picture's corner moving
/// with whatever was cut off its top and left, and nothing is handed on
/// to a display - the caller does that (`rtg.RefreshRect`).
///
/// Each pixel is mixed with the one under it by its coverage: fully
/// covered goes down as it is, uncovered leaves the buffer alone. Below
/// full strength the coverage is taken times `alpha` / 256. A format
/// without coverage - `rgb565`, `rgb24` - covers by `alpha` alone, and so
/// does a picture with `RTGPIXF_OPAQUE` in its flags, whatever its
/// pixels' top byte holds: a window's buffer laid over the display as it
/// fades.
///
/// Where `dest` is a board's and the board has an engine that takes the
/// job, the engine lays it (`rtg.BlendPixels`). Otherwise the rows are
/// cut into bands and every core lays its share at once; a rectangle of
/// few pixels is laid by the caller alone, and so is a picture that lies
/// in the rows it is laid over.
///
/// CONTEXT:
/// - Waits: for exec's workers, where the rows are shared; for the
///   board's engine, where it takes the job.
/// - Interrupts: no. The work is unbounded.
/// - Locks: none taken. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The picture stays the caller's and is only
/// read.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BlendBitMapRect`, `BltBitMapRects`, `BlendPixelArray`
///
/// EXAMPLES:
/// ```zig
/// // A window's buffer over the display, half faded in.
/// const picture: rtg.RtgPixels = .{ .pixels = window.pixels, .pitch = window.pitch, .format = window.format, .flags = rtg.RTGPIXF_OPAQUE };
/// _ = gb.BlendBitMapPixels(display, &.{ .x = 40, .y = 30, .width = 320, .height = 200 }, &picture, 128);
/// ```
pub fn BlendBitMapPixels(gb: *GraphicsBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, alpha: u32) i32 {
    const picture = pixels.pixels orelse return graphics.GERR_BAD_SIZE;
    if (dest.pixels == null) return graphics.GERR_BAD_SIZE;
    if (rastport.packPen(pixels.format, 0) == null or rastport.packPen(dest.format, 0) == null) return graphics.GERR_BAD_FORMAT;
    if (dest.board != null and gb.rtg_base.BlendPixels(dest, area, pixels, alpha) == rtg.errors.RTGERR_OK) return graphics.GERR_OK;
    if (area.width <= 0 or area.height <= 0) return graphics.GERR_OK;
    // Wide, so that a rectangle near the end of the numbers cannot wrap.
    const left = @max(@as(i64, area.x), 0);
    const top = @max(@as(i64, area.y), 0);
    const right = @min(@as(i64, area.x) + area.width, @as(i64, dest.width));
    const bottom = @min(@as(i64, area.y) + area.height, @as(i64, dest.height));
    if (right <= left or bottom <= top) return graphics.GERR_OK;
    // The picture's corner moved by what the cut took off. A corner
    // before the picture's first byte is no picture.
    const x = @as(i64, pixels.x) + left - area.x;
    const y = @as(i64, pixels.y) + top - area.y;
    if (pixels.x < 0 or pixels.y < 0) return graphics.GERR_BAD_SIZE;
    const bytes = rastport.formatBits(pixels.format) / 8;
    const corner = picture + @as(usize, @intCast(y)) * pixels.pitch + @as(usize, @intCast(x)) * bytes;
    const on = Rect{ .min_x = @intCast(left), .min_y = @intCast(top), .max_x = @intCast(right), .max_y = @intCast(bottom) };
    _lay.lay(gb, @ptrCast(dest), on, corner, pixels.pitch, pixels.format, alpha, pixels.flags & rtg.RTGPIXF_OPAQUE != 0);
    return graphics.GERR_OK;
}
