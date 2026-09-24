// SPDX-License-Identifier: MPL-2.0
//! SetBoardGap: The offset added to every coordinate, for glass whose
//! visible area does not start where the controller's does.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const _board = @import("../board/_board.zig");

/// Sets the offset added to every coordinate a board sends.
///
/// SYNOPSIS:
/// ```zig
/// fn SetBoardGap(_: *RtgBase, board: *rtg.RtgBoard, gap_x: u32, gap_y: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -216.
///
/// INPUTS:
/// - `board` - the board.
/// - `gap_x` - columns to skip at the left.
/// - `gap_y` - rows to skip at the top.
///
/// RESULT:
/// `RTGERR_OK`, `RTGERR_NOT_SUPPORTED`, or what the driver answered.
///
/// BEHAVIOR:
/// For glass whose visible area does not start where the controller's does.
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
/// `MirrorBoard`, `SwapBoardAxes`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.SetBoardGap(board, 0, 8);
/// ```
pub fn SetBoardGap(_: *RtgBase, board: *rtg.RtgBoard, gap_x: u32, gap_y: u32) i32 {
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const set_gap = ops.set_gap orelse return err.RTGERR_NOT_SUPPORTED;
    const code = set_gap(board, gap_x, gap_y);
    if (code != err.RTGERR_OK) return code;
    board.info.gap_x = gap_x;
    board.info.gap_y = gap_y;
    return err.RTGERR_OK;
}
