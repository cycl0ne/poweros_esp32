// SPDX-License-Identifier: MPL-2.0
//! GetBoardInfo: Fill in `info`, of which `size` bytes are there - pass
//! @sizeOf(RtgBoardInfo).

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const copyOut = _board.copyOut;
const countModes = _board.countModes;
const privateOf = _board.privateOf;
const _board = @import("_board.zig");

/// Reads what a board is and what state it is in.
///
/// SYNOPSIS:
/// ```zig
/// fn GetBoardInfo(_: *RtgBase, board: *rtg.RtgBoard, info: *rtg.RtgBoardInfo, size: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -60.
///
/// INPUTS:
/// - `board` - the board.
/// - `info` - where the answer goes.
/// - `size` - how many bytes `info` has: `@sizeOf(RtgBoardInfo)`.
///
/// RESULT:
/// How many bytes were written. A caller built against an older SDK with a
/// smaller structure gets that much; check the count before trusting a
/// field near the end.
///
/// BEHAVIOR:
/// The display memory still free, its largest piece, the number of modes
/// and the brightness are read fresh; the rest is what the board already
/// says about itself. After `SwapBoardAxes` the width and height are the
/// turned ones, since they are what a caller draws on.
///
/// CONTEXT:
/// - Waits: if the driver's brightness read does, and while another task
///   holds the board's lock - through a show, which may last a frame.
/// - Interrupts: no.
/// - Locks: takes the board's lock while it reads what is free of the
///   display memory. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetBoardStats`, `BoardMode`
///
/// EXAMPLES:
/// ```zig
/// var info: rtg.RtgBoardInfo = .{};
/// _ = rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
/// ```
pub fn GetBoardInfo(rb: *RtgBase, board: *rtg.RtgBoard, info: *rtg.RtgBoardInfo, size: u32) u32 {
    const private = privateOf(board);
    // The display memory's free pieces are a list the board's lock holds
    // still.
    _board.obtain(rb, board);
    board.info.memory_free = private.arena.free_bytes;
    board.info.memory_largest = private.arena.largest(rb.sys_base);
    _board.release(rb, board);
    board.info.modes = countModes(board);
    if (board.ops) |ops| {
        if (ops.brightness) |read| board.info.brightness = read(board);
    }
    return copyOut(rtg.RtgBoardInfo, &board.info, info, size);
}
