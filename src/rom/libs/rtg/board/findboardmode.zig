// SPDX-License-Identifier: MPL-2.0
//! FindBoardMode: The board's mode of that size and format, or null.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const _board = @import("_board.zig");

/// Finds a board's mode by its size and format.
///
/// SYNOPSIS:
/// ```zig
/// fn FindBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, format: u32) ?*rtg.RtgMode
/// ```
///
/// SINCE: 1.0. LVO -76.
///
/// INPUTS:
/// - `board` - the board.
/// - `width` - the width wanted, or 0 for any.
/// - `height` - the height wanted, or 0 for any.
/// - `format` - the pixel format wanted, or 0 for any.
///
/// RESULT:
/// The first mode that matches, or null. With all three 0, the board's
/// default mode - the one marked `RTGMF_DEFAULT`, or else its first.
///
/// BEHAVIOR:
/// Each 0 matches anything, so a caller can ask for any 1024-wide mode, or
/// the default.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It calls through the jump table.
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
/// `NextBoardMode`, `SetBoardMode`
///
/// EXAMPLES:
/// ```zig
/// const mode = rb.FindBoardMode(board, 1024, 600, 0) orelse return error.NoMode;
/// ```
pub fn FindBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, format: u32) ?*rtg.RtgMode {
    const rtg_lib = rb.iface();
    var best: ?*rtg.RtgMode = null;
    var mode = rtg_lib.NextBoardMode(board, null);
    while (mode) |m| : (mode = rtg_lib.NextBoardMode(board, m)) {
        if (width != 0 and m.width != width) continue;
        if (height != 0 and m.height != height) continue;
        if (format != 0 and @intFromEnum(m.format) != format) continue;
        // With nothing asked for, the board's default is the answer.
        if (width == 0 and height == 0 and format == 0) {
            if (m.flags & rtg.boards.RTGMF_DEFAULT != 0) return m;
            if (best == null) best = m;
            continue;
        }
        return m;
    }
    return best;
}
