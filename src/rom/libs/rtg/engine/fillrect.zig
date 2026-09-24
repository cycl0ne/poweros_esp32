// SPDX-License-Identifier: MPL-2.0
//! FillRect: Fill a rectangle, in the buffer's format, right-aligned.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const clip = _engine.clip;
const boardOf = _engine.boardOf;
const err = rtg.errors;
const drawable = _engine.drawable;
const _engine = @import("_engine.zig");

/// Fills a rectangle of a buffer with the board's engine.
///
/// SYNOPSIS:
/// ```zig
/// fn FillRect(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -128.
///
/// INPUTS:
/// - `dest` - the buffer, of a board.
/// - `area` - the rectangle.
/// - `color` - one pixel in the buffer's format, right-aligned.
///
/// RESULT:
/// `RTGERR_OK` - also when none of the rectangle is inside the buffer -
/// `RTGERR_BAD_ARG` for a buffer with no pixels or no board,
/// `RTGERR_NOT_SUPPORTED` unless the engine fills, or what the driver
/// answered.
///
/// BEHAVIOR:
/// The rectangle is cut to the buffer here, so the driver never clips.
/// The library draws nothing itself: a board without the engine says so,
/// and the layer above does the work in software.
///
/// CONTEXT:
/// - Waits: only if the driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Forbid: must not be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InvertRect`, `PackRtgColor`, `WaitBlit`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.FillRect(buffer, &.{ .x = 0, .y = 0, .width = 100, .height = 50 }, colour);
/// ```
pub fn FillRect(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) i32 {
    if (!drawable(dest)) return err.RTGERR_BAD_ARG;
    const board = boardOf(dest) orelse return err.RTGERR_BAD_ARG;
    const cut = clip(dest, area) orelse return err.RTGERR_OK;
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const fill = ops.fill_rect orelse return err.RTGERR_NOT_SUPPORTED;
    return fill(board, dest, &cut, color);
}
