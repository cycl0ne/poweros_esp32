// SPDX-License-Identifier: MPL-2.0
//! GetBoardStats: What a board that refreshes itself has been through.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const copyOut = _board.copyOut;
const privateOf = _board.privateOf;
const _board = @import("_board.zig");

/// Reads what a board that refreshes itself has been through.
///
/// SYNOPSIS:
/// ```zig
/// fn GetBoardStats(_: *RtgBase, board: *rtg.RtgBoard, stats: *rtg.RtgBoardStats, size: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -64.
///
/// INPUTS:
/// - `board` - the board.
/// - `stats` - where the answer goes.
/// - `size` - how many bytes `stats` has: `@sizeOf(RtgBoardStats)`.
///
/// RESULT:
/// How many bytes were written, as for `GetBoardInfo`.
///
/// BEHAVIOR:
/// The driver fills in what it counts - frames sent, frames late - and the
/// library adds how many times a buffer was shown. All zeroes but that for
/// a board that counts nothing. `BoardControl(RTGCTRL_RESET_STATS)` starts
/// the counts again.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
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
/// `GetBoardInfo`, `BoardControl`
///
/// EXAMPLES:
/// ```zig
/// var stats: rtg.RtgBoardStats = .{};
/// _ = rb.GetBoardStats(board, &stats, @sizeOf(rtg.RtgBoardStats));
/// ```
pub fn GetBoardStats(_: *RtgBase, board: *rtg.RtgBoard, stats: *rtg.RtgBoardStats, size: u32) u32 {
    var whole: rtg.RtgBoardStats = .{};
    if (board.ops) |ops| {
        if (ops.stats) |read| read(board, &whole);
    }
    whole.buffer_swaps = privateOf(board).buffer_swaps;
    return copyOut(rtg.RtgBoardStats, &whole, stats, size);
}
