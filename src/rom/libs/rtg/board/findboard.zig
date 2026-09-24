// SPDX-License-Identifier: MPL-2.0
//! FindBoard: The board of that name, or null.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const _board = @import("_board.zig");

/// Finds a board by its name.
///
/// SYNOPSIS:
/// ```zig
/// fn FindBoard(rb: *RtgBase, board_name: [*:0]const u8) ?*rtg.RtgBoard
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// - `board_name` - the name, as `CreateBoardTagList` gave it.
///
/// RESULT:
/// The board, or null.
///
/// BEHAVIOR:
/// An exact match on the name.
///
/// CONTEXT:
/// - Waits: yes, while another task is changing the board list.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The board is not held once the call returns: one
/// another task may delete is the caller's to agree on with that task.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NextBoard`, `CreateBoardTagList`
///
/// EXAMPLES:
/// ```zig
/// const board = rb.FindBoard("rgb0") orelse return;
/// ```
pub fn FindBoard(rb: *RtgBase, board_name: [*:0]const u8) ?*rtg.RtgBoard {
    const sys = rb.sys_base;
    // Held while it is searched, so no board leaves it under the search.
    sys.ObtainSemaphoreShared(&rb.board_lock);
    defer sys.ReleaseSemaphore(&rb.board_lock);
    const node = sys.FindName(&rb.boards, board_name) orelse return null;
    return @fieldParentPtr("node", node);
}
