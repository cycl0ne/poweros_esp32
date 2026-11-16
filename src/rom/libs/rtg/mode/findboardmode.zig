// SPDX-License-Identifier: MPL-2.0
//! FindBoardMode: The number of the board's mode of exactly that size,
//! refresh and format.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const _mode = @import("_mode.zig");

/// Finds a board's mode by its size, refresh and format.
///
/// SYNOPSIS:
/// ```zig
/// fn FindBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, refresh_mhz: u32, format: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -76.
///
/// INPUTS:
/// - `board` - the board.
/// - `width` - the width wanted, or `RTG_ANY`.
/// - `height` - the height wanted, or `RTG_ANY`.
/// - `refresh_mhz` - the refresh wanted, in milli-Hertz as the mode says
///   it, or `RTG_ANY`.
/// - `format` - the pixel format wanted, as a number, or `RTG_ANY`.
///
/// RESULT:
/// The number of a mode that is exactly that, or 0. Where several are,
/// the board's default if it is one of them, else the first of the list.
///
/// BEHAVIOR:
/// Each `RTG_ANY` matches whatever the mode has, so a caller can ask for
/// any mode 1024 wide, and all four `RTG_ANY` is the board's default
/// mode. A mode that is only near what was asked is not answered:
/// `BestBoardMode` does that.
///
/// CONTEXT:
/// - Waits: while another task holds the board's lock.
/// - Interrupts: no.
/// - Locks: takes the board's lock. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BestBoardMode`, `GetBoardModes`, `SetBoardMode`
///
/// EXAMPLES:
/// ```zig
/// const mode_id = rb.FindBoardMode(board, 1024, 600, rtg.RTG_ANY, rtg.RTG_ANY);
/// if (mode_id == 0) return error.NoMode;
/// ```
pub fn FindBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, refresh_mhz: u32, format: u32) u32 {
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    const record = _mode.find(board, width, height, refresh_mhz, format) orelse return 0;
    return record.mode.id;
}
