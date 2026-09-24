// SPDX-License-Identifier: MPL-2.0
//! CopyRect: Copy a rectangle.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const clipCopy = _engine.clipCopy;
const boardOf = _engine.boardOf;
const err = rtg.errors;
const drawable = _engine.drawable;
const _engine = @import("_engine.zig");

/// Copies a rectangle between buffers with the board's engine.
///
/// SYNOPSIS:
/// ```zig
/// fn CopyRect(_: *RtgBase, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, copy: *const rtg.RtgCopy) i32
/// ```
///
/// SINCE: 1.0. LVO -136.
///
/// INPUTS:
/// - `src` - the buffer copied from.
/// - `dest` - the buffer copied to; it may be `src`.
/// - `copy` - where from, where to, and how big.
///
/// RESULT:
/// As for `FillRect`.
///
/// BEHAVIOR:
/// The rectangles are cut to both buffers here. The two may be one buffer
/// and may overlap; the engine is what copies in the right order.
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
/// `FillRect`, `WaitBlit`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.CopyRect(buffer, buffer, &.{ .src_x = 0, .src_y = 10, .dest_x = 0, .dest_y = 0, .width = 800, .height = 590 });
/// ```
pub fn CopyRect(_: *RtgBase, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, copy: *const rtg.RtgCopy) i32 {
    if (!drawable(src) or !drawable(dest)) return err.RTGERR_BAD_ARG;
    const board = boardOf(dest) orelse return err.RTGERR_BAD_ARG;
    const cut = clipCopy(src, dest, copy) orelse return err.RTGERR_OK;
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const copy_rect = ops.copy_rect orelse return err.RTGERR_NOT_SUPPORTED;
    return copy_rect(board, src, dest, &cut);
}
