// SPDX-License-Identifier: MPL-2.0
//! SetBoardBrightness: 0 to 100, the right way round whatever the part
//! does.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const _board = @import("../board/_board.zig");

/// Sets a board's brightness.
///
/// SYNOPSIS:
/// ```zig
/// fn SetBoardBrightness(_: *RtgBase, board: *rtg.RtgBoard, percent: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -120.
///
/// INPUTS:
/// - `board` - the board.
/// - `percent` - 0 to 100; more is 100.
///
/// RESULT:
/// `RTGERR_OK`, `RTGERR_NOT_SUPPORTED`, or what the driver answered.
///
/// BEHAVIOR:
/// 0 is dark and 100 is full, whichever way round the part itself counts.
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
/// `BoardBrightness`, `SetBoardDisplay`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.SetBoardBrightness(board, 60);
/// ```
pub fn SetBoardBrightness(_: *RtgBase, board: *rtg.RtgBoard, percent: u32) i32 {
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const set = ops.set_brightness orelse return err.RTGERR_NOT_SUPPORTED;
    const want = @min(percent, 100);
    const code = set(board, want);
    if (code == err.RTGERR_OK) board.info.brightness = want;
    return code;
}
