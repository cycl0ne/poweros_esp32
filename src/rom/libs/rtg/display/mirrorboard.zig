// SPDX-License-Identifier: MPL-2.0
//! MirrorBoard: Mirror the picture about each axis.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const _board = @import("../board/_board.zig");

/// Mirrors a board's picture about each axis.
///
/// SYNOPSIS:
/// ```zig
/// fn MirrorBoard(_: *RtgBase, board: *rtg.RtgBoard, mirror_x: bool, mirror_y: bool) i32
/// ```
///
/// SINCE: 1.0. LVO -208.
///
/// INPUTS:
/// - `board` - the board.
/// - `mirror_x` - flip left and right.
/// - `mirror_y` - flip top and bottom.
///
/// RESULT:
/// `RTGERR_OK`, `RTGERR_NOT_SUPPORTED` unless the board can do it itself,
/// or what the driver answered.
///
/// BEHAVIOR:
/// Only a board that can turn the picture itself does it; otherwise that
/// is the business of whoever draws.
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
/// `SwapBoardAxes`, `SetBoardGap`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.MirrorBoard(board, true, false);
/// ```
pub fn MirrorBoard(_: *RtgBase, board: *rtg.RtgBoard, mirror_x: bool, mirror_y: bool) i32 {
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const mirror = ops.mirror orelse return err.RTGERR_NOT_SUPPORTED;
    const code = mirror(board, mirror_x, mirror_y);
    if (code != err.RTGERR_OK) return code;
    board.info.mirror_x = @intFromBool(mirror_x);
    board.info.mirror_y = @intFromBool(mirror_y);
    return err.RTGERR_OK;
}
