// SPDX-License-Identifier: MPL-2.0
//! BestBoardMode: The board's mode nearest a wish.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const _mode = @import("_mode.zig");

/// Finds the mode of a board that comes nearest a wish.
///
/// SYNOPSIS:
/// ```zig
/// fn BestBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, refresh_mhz: u32, format: u32, mode: ?*rtg.RtgMode) u32
/// ```
///
/// SINCE: 1.19. LVO -224.
///
/// INPUTS:
/// - `board` - the board.
/// - `width` - the width wished for, or `RTG_ANY`.
/// - `height` - the height wished for, or `RTG_ANY`.
/// - `refresh_mhz` - the refresh wished for, in milli-Hertz, or `RTG_ANY`.
/// - `format` - the pixel format wished for, as a number, or `RTG_ANY`.
/// - `mode` - where the mode found is copied to, or null.
///
/// RESULT:
/// The number of the mode, and what it is in `mode`. 0, and `mode` left
/// as it was, only on a board that has no mode.
///
/// BEHAVIOR:
/// A format wished for is looked for among the board's modes of that
/// format, where it has any; else among all of them. Then the size
/// decides: a mode of the size wished for where there is one, else the
/// smallest that holds it, else the largest. Of several modes of one size
/// the refresh nearest the one wished for is taken - with the refresh left
/// open the board's default where it is of that size, else the highest. A
/// wish that leaves both sides of the size open is for the size of the
/// board's default mode.
///
/// So a display of one mode always answers that mode: whoever asks for
/// another size is handed the board's, and sees which it got by comparing
/// `mode` with what it asked for.
///
/// CONTEXT:
/// - Waits: while another task holds the board's lock.
/// - Interrupts: no.
/// - Locks: takes the board's lock. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated: the copy is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindBoardMode`, `GetBoardModes`, `ShowBoard`
///
/// EXAMPLES:
/// ```zig
/// var got: rtg.RtgMode = .{};
/// const mode_id = rb.BestBoardMode(board, 800, 600, rtg.RTG_ANY, rtg.RTG_ANY, &got);
/// if (got.width != 800 or got.height != 600) tellOf(&got);
/// ```
pub fn BestBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, refresh_mhz: u32, format: u32, mode: ?*rtg.RtgMode) u32 {
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    const record = _mode.best(board, width, height, refresh_mhz, format) orelse return 0;
    if (mode) |into| into.* = record.mode;
    return record.mode.id;
}
