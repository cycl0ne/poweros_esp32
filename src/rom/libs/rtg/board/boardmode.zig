// SPDX-License-Identifier: MPL-2.0
//! BoardMode: The mode the board is in now, or null for none.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const privateOf = _board.privateOf;
const _board = @import("_board.zig");

/// Tells which mode a board is in.
///
/// SYNOPSIS:
/// ```zig
/// fn BoardMode(_: *RtgBase, board: *rtg.RtgBoard) ?*rtg.RtgMode
/// ```
///
/// SINCE: 1.0. LVO -84.
///
/// INPUTS:
/// - `board` - the board.
///
/// RESULT:
/// The mode, or null before `SetBoardMode`.
///
/// BEHAVIOR:
/// The mode the last `SetBoardMode` that worked put the board in.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads one field.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetBoardMode`, `GetBoardInfo`
///
/// EXAMPLES:
/// ```zig
/// const mode = rb.BoardMode(board) orelse return error.NoMode;
/// ```
pub fn BoardMode(_: *RtgBase, board: *rtg.RtgBoard) ?*rtg.RtgMode {
    return privateOf(board).mode;
}
