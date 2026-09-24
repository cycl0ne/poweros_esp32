// SPDX-License-Identifier: MPL-2.0
//! BoardDisplayBitMap: The buffer the board is showing, or null.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;

/// Tells which buffer a board is showing.
///
/// SYNOPSIS:
/// ```zig
/// fn BoardDisplayBitMap(_: *RtgBase, board: *rtg.RtgBoard) ?*rtg.RtgBitMap
/// ```
///
/// SINCE: 1.0. LVO -104.
///
/// INPUTS:
/// - `board` - the board.
///
/// RESULT:
/// The buffer, or null.
///
/// BEHAVIOR:
/// Its first seven fields are a drawing surface, so a caller that wants to
/// draw on the display can use it directly.
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
/// `ShowBitMap`
///
/// EXAMPLES:
/// ```zig
/// const shown = rb.BoardDisplayBitMap(board) orelse return;
/// ```
pub fn BoardDisplayBitMap(_: *RtgBase, board: *rtg.RtgBoard) ?*rtg.RtgBitMap {
    return board.showing;
}
