// SPDX-License-Identifier: MPL-2.0
//! BoardBrightness: What it is now, 0 to 100.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;

/// Reads a board's brightness.
///
/// SYNOPSIS:
/// ```zig
/// fn BoardBrightness(_: *RtgBase, board: *rtg.RtgBoard) u32
/// ```
///
/// SINCE: 1.0. LVO -124.
///
/// INPUTS:
/// - `board` - the board.
///
/// RESULT:
/// 0 to 100: what the driver reads, or else the last that was set. 0 for a
/// board with no operations.
///
/// BEHAVIOR:
/// A board that can read its level back is asked, and the answer is kept
/// in its information; one that cannot answers what was last set.
///
/// CONTEXT:
/// - Waits: only if the driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: no spinlock may be held: a driver may wait.
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
/// const level = rb.BoardBrightness(board);
/// ```
pub fn BoardBrightness(_: *RtgBase, board: *rtg.RtgBoard) u32 {
    const ops = board.ops orelse return 0;
    const read = ops.brightness orelse return board.info.brightness;
    board.info.brightness = read(board);
    return board.info.brightness;
}
