// SPDX-License-Identifier: MPL-2.0
//! NextBoard: The next board after `after`, or the first for null.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;

/// Walks the list of boards.
///
/// SYNOPSIS:
/// ```zig
/// fn NextBoard(rb: *RtgBase, after: ?*rtg.RtgBoard) ?*rtg.RtgBoard
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `after` - the board to go on from, or null for the first.
///
/// RESULT:
/// The next board, or null at the end.
///
/// BEHAVIOR:
/// The boards, highest priority first: as their drivers made them, the
/// picture the firmware lit last. The first is the machine's display. A
/// board whose device has gone (`RTGBF_GONE`) is passed over; `after` may
/// be such a board, and the walk goes on behind it.
///
/// CONTEXT:
/// - Waits: yes, while another task is changing the board list.
/// - Interrupts: no.
/// - Locks: takes the board list's lock, shared, for the step. No spinlock
///   may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The list is held for each step, not between
/// them: a board is never freed for a program, so `after` is a board for
/// as long as the machine runs.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindBoard`, `BindRtgDrivers`
///
/// EXAMPLES:
/// ```zig
/// var board = rb.NextBoard(null);
/// while (board) |b| : (board = rb.NextBoard(b)) show(b);
/// ```
pub fn NextBoard(rb: *RtgBase, after: ?*rtg.RtgBoard) ?*rtg.RtgBoard {
    const sys = rb.sys_base;
    // Held for the step, so the board after `after` is not taken out from
    // between them.
    sys.ObtainSemaphoreShared(&rb.board_lock);
    defer sys.ReleaseSemaphore(&rb.board_lock);
    var node = if (after) |board| board.node.next() else rb.boards.first();
    while (node) |one| : (node = one.next()) {
        const board: *rtg.RtgBoard = @fieldParentPtr("node", one);
        // One whose device has gone is still a handle, and no display.
        if (board.info.flags & rtg.boards.RTGBF_GONE == 0) return board;
    }
    return null;
}
