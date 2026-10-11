// SPDX-License-Identifier: MPL-2.0
//! BlendPixels: Lay pixels of one's own over a rectangle by their
//! coverage.

const std = @import("std");
const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _engine = @import("_engine.zig");
const clip = _engine.clip;
const boardOf = _engine.boardOf;
const drawable = _engine.drawable;
const err = rtg.errors;

/// Lays pixels of the caller's own over a rectangle of a buffer with the
/// board's engine, each by its own coverage.
///
/// SYNOPSIS:
/// ```zig
/// fn BlendPixels(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, alpha: u32) i32
/// ```
///
/// SINCE: 1.4. LVO -244.
///
/// INPUTS:
/// - `dest` - the buffer, of a board.
/// - `area` - the rectangle.
/// - `pixels` - the picture: its first byte, pitch and format, and the
///   pixel that lands on the rectangle's top left corner. The rectangle's
///   size is how much of it is read.
/// - `alpha` - 0 to 255, multiplied into every pixel's coverage; 255
///   leaves the coverage as it is.
///
/// RESULT:
/// `RTGERR_OK` - also when none of the rectangle is inside the buffer -
/// `RTGERR_BAD_ARG` for a buffer with no pixels or no board, or a
/// picture with none, `RTGERR_NOT_SUPPORTED` unless the engine takes the
/// job, or what the driver answered.
///
/// BEHAVIOR:
/// Each pixel is mixed with the one under it by its coverage: fully
/// covered goes down as it is, uncovered leaves the buffer alone. A
/// format without coverage - `rgb565`, `rgb24` - covers by `alpha` alone.
/// The rectangle is cut to the buffer here, and the picture's corner
/// moves with whatever was cut off its top and left, so a cut picture is
/// cut rather than slid. Which formats and sizes the engine takes is the
/// driver's to say; the library draws nothing itself.
///
/// CONTEXT:
/// - Waits: only if the driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: no spinlock may be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The picture stays the caller's and is only read;
/// it has to be where the board's engine can read it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BlendRect`, `ScalePixels`, `CopyRect`
///
/// EXAMPLES:
/// ```zig
/// const picture: rtg.RtgPixels = .{ .pixels = icon.ptr, .pitch = 64 * 4, .format = .bgra32 };
/// _ = rb.BlendPixels(buffer, &.{ .x = 10, .y = 10, .width = 64, .height = 64 }, &picture, 255);
/// ```
pub fn BlendPixels(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, alpha: u32) i32 {
    if (!drawable(dest) or pixels.pixels == null) return err.RTGERR_BAD_ARG;
    const board = boardOf(dest) orelse return err.RTGERR_BAD_ARG;
    const cut = clip(dest, area) orelse return err.RTGERR_OK;
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const blend = ops.blend_pixels orelse return err.RTGERR_NOT_SUPPORTED;
    // The picture's corner moved by what the cut took off, worked out
    // wide: a corner that would leave the numbers is no picture.
    const x = @as(i64, pixels.x) + cut.x - area.x;
    const y = @as(i64, pixels.y) + cut.y - area.y;
    if (x > std.math.maxInt(i32) or y > std.math.maxInt(i32)) return err.RTGERR_BAD_ARG;
    var moved = pixels.*;
    moved.x = @intCast(x);
    moved.y = @intCast(y);
    return blend(board, dest, &cut, &moved, @min(alpha, 255));
}
