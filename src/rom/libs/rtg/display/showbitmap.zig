// SPDX-License-Identifier: MPL-2.0
//! ShowBitMap: Show that buffer, its pixel (x, y) at the top left; null
//! shows nothing.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const privateOf = _board.privateOf;
const _board = @import("../board/_board.zig");

/// Shows a buffer on a board's display.
///
/// SYNOPSIS:
/// ```zig
/// fn ShowBitMap(_: *RtgBase, board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap, x: u32, y: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -100.
///
/// INPUTS:
/// - `board` - the board.
/// - `bitmap` - one of its buffers made `RTGBMF_DISPLAYABLE`, or null to
///   show nothing.
/// - `x` - the buffer's column at the display's left edge.
/// - `y` - its row at the top edge.
///
/// RESULT:
/// `RTGERR_OK`, or: `RTGERR_BAD_ARG` for another board's buffer,
/// `RTGERR_NOT_DISPLAYABLE`, `RTGERR_NOT_SUPPORTED` for a board that
/// cannot show buffers or cannot pan to a non-zero `x` or `y`, or what the
/// driver answered.
///
/// BEHAVIOR:
/// The buffer shown before is no longer marked showing, so it can be
/// freed; the new one is, so it cannot.
///
/// CONTEXT:
/// - Waits: only if the driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Forbid: must not be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The buffer stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BoardDisplayBitMap`, `AllocBitMap`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.ShowBitMap(board, buffer, 0, 0);
/// ```
pub fn ShowBitMap(_: *RtgBase, board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap, x: u32, y: u32) i32 {
    const private = privateOf(board);
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const show = ops.show_bitmap orelse return err.RTGERR_NOT_SUPPORTED;

    if (bitmap) |bm| {
        if (bm.board != @as(?*anyopaque, @ptrCast(board))) return err.RTGERR_BAD_ARG;
        if (bm.flags & rtg.bitmaps.RTGBMF_DISPLAYABLE == 0) return err.RTGERR_NOT_DISPLAYABLE;
    }
    const code = show(board, bitmap, x, y);
    if (code != err.RTGERR_OK) return code;

    if (board.showing) |old| old.flags &= ~rtg.bitmaps.RTGBMF_SHOWING;
    board.showing = bitmap;
    if (bitmap) |bm| {
        bm.flags |= rtg.bitmaps.RTGBMF_SHOWING;
        board.info.flags |= rtg.boards.RTGBF_SHOWING;
        private.buffer_swaps +%= 1;
    } else {
        board.info.flags &= ~rtg.boards.RTGBF_SHOWING;
    }
    return err.RTGERR_OK;
}
