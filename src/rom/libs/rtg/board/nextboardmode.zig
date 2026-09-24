// SPDX-License-Identifier: MPL-2.0
//! NextBoardMode: The next mode of a board, or its first for null.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const _board = @import("_board.zig");

/// Walks a board's modes.
///
/// SYNOPSIS:
/// ```zig
/// fn NextBoardMode(_: *RtgBase, board: *rtg.RtgBoard, after: ?*rtg.RtgMode) ?*rtg.RtgMode
/// ```
///
/// SINCE: 1.0. LVO -72.
///
/// INPUTS:
/// - `board` - the board.
/// - `after` - the mode to go on from, or null for the first.
///
/// RESULT:
/// The next mode, or null at the end.
///
/// BEHAVIOR:
/// The modes are the driver's, fixed when the board was made.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe: the modes do not change after the board is made.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The modes are the board's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindBoardMode`, `SetBoardMode`
///
/// EXAMPLES:
/// ```zig
/// var mode = rb.NextBoardMode(board, null);
/// while (mode) |m| : (mode = rb.NextBoardMode(board, m)) list(m);
/// ```
pub fn NextBoardMode(_: *RtgBase, board: *rtg.RtgBoard, after: ?*rtg.RtgMode) ?*rtg.RtgMode {
    const node = if (after) |mode| mode.node.next() else board.modes.first();
    return @fieldParentPtr("node", node orelse return null);
}
