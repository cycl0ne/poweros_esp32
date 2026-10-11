// SPDX-License-Identifier: MPL-2.0
//! ScalePixels: Lay pixels of one's own over a rectangle at its size.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _engine = @import("_engine.zig");
const boardOf = _engine.boardOf;
const drawable = _engine.drawable;
const err = rtg.errors;

/// Scales a part of a picture of the caller's own to a rectangle's size
/// with the board's engine, and lays it over the rectangle by its
/// coverage.
///
/// SYNOPSIS:
/// ```zig
/// fn ScalePixels(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, width: u32, height: u32) i32
/// ```
///
/// SINCE: 1.4. LVO -252.
///
/// INPUTS:
/// - `dest` - the buffer, of a board.
/// - `area` - where the picture lands and how big it becomes.
/// - `pixels` - the picture: its first byte, pitch and format, and the
///   top left corner of the part taken.
/// - `width` - the part's width, in the picture's pixels.
/// - `height` - its height.
///
/// RESULT:
/// `RTGERR_OK` - also for an empty rectangle or part - `RTGERR_BAD_ARG`
/// for a buffer with no pixels or no board, or a picture with none,
/// `RTGERR_NOT_SUPPORTED` for a rectangle not wholly inside the buffer or
/// a job the engine does not take, or what the driver answered.
///
/// BEHAVIOR:
/// Every pixel of the rectangle is the picture's colour at that place,
/// mixed from the pixels round it, and is laid over the buffer by its
/// coverage as `BlendPixels` lays it. The rectangle is not cut to the
/// buffer: a cut would move the picture under it. Which formats and
/// which ratios the engine takes is the driver's to say - an engine that
/// scales in fixed steps takes only the sizes those steps reach exactly -
/// and the library draws nothing itself.
///
/// CONTEXT:
/// - Waits: only if the driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: no spinlock may be held: a driver may wait.
/// - Process: a Task will do. The driver may allocate.
///
/// OWNERSHIP:
/// Nothing stays allocated. The picture stays the caller's and is only
/// read; it has to be where the board's engine can read it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BlendPixels`, `CopyRect`
///
/// EXAMPLES:
/// ```zig
/// const picture: rtg.RtgPixels = .{ .pixels = photo.ptr, .pitch = 320 * 4, .format = .bgra32 };
/// _ = rb.ScalePixels(buffer, &.{ .x = 0, .y = 0, .width = 640, .height = 400 }, &picture, 320, 200);
/// ```
pub fn ScalePixels(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, width: u32, height: u32) i32 {
    if (!drawable(dest) or pixels.pixels == null) return err.RTGERR_BAD_ARG;
    const board = boardOf(dest) orelse return err.RTGERR_BAD_ARG;
    if (area.width <= 0 or area.height <= 0 or width == 0 or height == 0) return err.RTGERR_OK;
    if (area.x < 0 or area.y < 0) return err.RTGERR_NOT_SUPPORTED;
    if (@as(i64, area.x) + area.width > dest.width or @as(i64, area.y) + area.height > dest.height) return err.RTGERR_NOT_SUPPORTED;
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const scale = ops.scale_pixels orelse return err.RTGERR_NOT_SUPPORTED;
    return scale(board, dest, area, pixels, width, height);
}
