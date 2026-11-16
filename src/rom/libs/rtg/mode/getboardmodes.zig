// SPDX-License-Identifier: MPL-2.0
//! GetBoardModes: Copy out a board's modes.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const _mode = @import("_mode.zig");

/// Copies out the modes a board can be put into.
///
/// SYNOPSIS:
/// ```zig
/// fn GetBoardModes(rb: *RtgBase, board: *rtg.RtgBoard, into: ?[*]rtg.RtgMode, count: u32) u32
/// ```
///
/// SINCE: 1.19. LVO -304.
///
/// INPUTS:
/// - `board` - the board.
/// - `into` - where the modes go, or null to ask how many there are.
/// - `count` - how many `into` has room for.
///
/// RESULT:
/// How many modes the board has, which may be more than were copied.
///
/// BEHAVIOR:
/// Up to `count` modes are copied, the larger picture first and of one
/// size the higher refresh. Each says its number, its size, format and
/// row length, its pixel clock and refresh, its name, and in its flags
/// whether it is the board's default (`RTGMF_DEFAULT`) and the mode the
/// board is in (`RTGMF_CURRENT`).
///
/// CONTEXT:
/// - Waits: while another task holds the board's lock - through a show,
///   which may last a frame.
/// - Interrupts: no.
/// - Locks: takes the board's lock. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated: the copies are the caller's, and hold no pointer
/// into the library.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindBoardMode`, `BestBoardMode`, `ShowBoard`
///
/// EXAMPLES:
/// ```zig
/// var found: [16]rtg.RtgMode = undefined;
/// const there = rb.GetBoardModes(board, &found, found.len);
/// for (found[0..@min(there, found.len)]) |*mode| list(mode);
/// ```
pub fn GetBoardModes(rb: *RtgBase, board: *rtg.RtgBoard, into: ?[*]rtg.RtgMode, count: u32) u32 {
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    var there: u32 = 0;
    var node = boards.privateOf(board).modes.first();
    while (node) |one| : (node = one.next()) {
        if (into != null and there < count) into.?[there] = _mode.recordOf(one).mode;
        there += 1;
    }
    return there;
}
