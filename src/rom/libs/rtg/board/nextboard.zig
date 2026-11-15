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
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// - `after` - the board to go on from, or null for the first.
///
/// RESULT:
/// The next board, or null at the end.
///
/// BEHAVIOR:
/// The boards alive, in the order they were made.
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
/// them: `after` must still be a board, which the caller agrees on with
/// any task that may delete one.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindBoard`, `CreateBoardTagList`
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
    const node = if (after) |board| board.node.next() else rb.boards.first();
    return @fieldParentPtr("node", node orelse return null);
}
