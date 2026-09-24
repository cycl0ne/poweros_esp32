// SPDX-License-Identifier: MPL-2.0
//! SetBoardDisplay: The display enable.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const _board = @import("../board/_board.zig");

/// Switches a board's display on or off.
///
/// SYNOPSIS:
/// ```zig
/// fn SetBoardDisplay(_: *RtgBase, board: *rtg.RtgBoard, on: bool) i32
/// ```
///
/// SINCE: 1.0. LVO -116.
///
/// INPUTS:
/// - `board` - the board.
/// - `on` - true for on.
///
/// RESULT:
/// `RTGERR_OK`, `RTGERR_NOT_SUPPORTED`, or what the driver answered.
///
/// BEHAVIOR:
/// The display's own enable, not the backlight: `SetBoardBrightness` is
/// that.
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
/// `SetBoardBrightness`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.SetBoardDisplay(board, true);
/// ```
pub fn SetBoardDisplay(_: *RtgBase, board: *rtg.RtgBoard, on: bool) i32 {
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const display = ops.display orelse return err.RTGERR_NOT_SUPPORTED;
    const code = display(board, on);
    if (code != err.RTGERR_OK) return code;
    if (on) {
        board.info.flags |= rtg.boards.RTGBF_DISPLAY_ON;
    } else {
        board.info.flags &= ~rtg.boards.RTGBF_DISPLAY_ON;
    }
    return err.RTGERR_OK;
}
