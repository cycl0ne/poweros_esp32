// SPDX-License-Identifier: MPL-2.0
//! SwapBoardAxes: Exchange the board's axes; with MirrorBoard that is
//! every right-angle turn.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const _board = @import("../board/_board.zig");

/// Exchanges a board's axes.
///
/// SYNOPSIS:
/// ```zig
/// fn SwapBoardAxes(_: *RtgBase, board: *rtg.RtgBoard, swap: bool) i32
/// ```
///
/// SINCE: 1.0. LVO -212.
///
/// INPUTS:
/// - `board` - the board.
/// - `swap` - true to exchange them.
///
/// RESULT:
/// `RTGERR_OK` - also when it is already that way - `RTGERR_NOT_SUPPORTED`,
/// or what the driver answered.
///
/// BEHAVIOR:
/// With `MirrorBoard` that is every right-angle turn. The board's width
/// and height in `GetBoardInfo` are exchanged too, since they are what a
/// caller draws on.
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
/// `MirrorBoard`, `GetBoardInfo`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.SwapBoardAxes(board, true);
/// ```
pub fn SwapBoardAxes(_: *RtgBase, board: *rtg.RtgBoard, swap: bool) i32 {
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const swap_xy = ops.swap_xy orelse return err.RTGERR_NOT_SUPPORTED;
    if ((board.info.swapped != 0) == swap) return err.RTGERR_OK;
    const code = swap_xy(board, swap);
    if (code != err.RTGERR_OK) return code;
    board.info.swapped = @intFromBool(swap);
    // What a caller draws on has turned with it. The driver has said what
    // a row costs now; only the two sides are the library's to exchange.
    const was_width = board.info.width;
    board.info.width = board.info.height;
    board.info.height = was_width;
    return err.RTGERR_OK;
}
