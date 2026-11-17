// SPDX-License-Identifier: MPL-2.0
//! ShowBoardPointer: the pointer laid over the picture, or not.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const composer = @import("../compose/_compose.zig");

/// Shows a board's pointer, or hides it.
///
/// SYNOPSIS:
/// ```zig
/// fn ShowBoardPointer(rb: *RtgBase, board: *rtg.RtgBoard, show: bool) i32
/// ```
///
/// SINCE: 1.1. LVO -148.
///
/// INPUTS:
/// - `board` - the board.
/// - `show` - true to lay the pointer over the picture, false to stop.
///
/// RESULT:
/// `RTGERR_OK`, `RTGERR_NOT_SUPPORTED` for a board without
/// `RTGBC_POINTER`, or what the driver answered.
///
/// BEHAVIOR:
/// The picture itself never holds the pointer: it is laid in on the way
/// to the glass, so hiding it leaves the picture exactly as it was
/// drawn. Shown with no image set, nothing appears until one is.
/// `RTGBF_POINTER` in `RtgBoardInfo.flags` says which it is.
///
/// On a board whose picture the library composes, a display that reads
/// the shown buffer itself is shown the library's picture while the
/// pointer is seen, and reads the buffer again once nothing lies over
/// the picture any more.
///
/// CONTEXT:
/// - Waits: for the board's compose lock while another task changes the
///   pointer or hands on what it drew, for the board's lock where the
///   library lays the pointer, and for a driver that sends the pointer's
///   rows over a bus.
/// - Interrupts: no. A driver may send the pointer's rows over a bus.
/// - Locks: takes the board's compose lock while it changes, and the
///   board's lock before it where the library lays the pointer; no
///   spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetBoardPointer`, `MoveBoardPointer`, `GetBoardInfo`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.ShowBoardPointer(board, false);
/// ```
pub fn ShowBoardPointer(rb: *RtgBase, board: *rtg.RtgBoard, show: bool) i32 {
    if (board.info.caps & rtg.boards.RTGBC_POINTER == 0) return err.RTGERR_NOT_SUPPORTED;
    return composer.showPointer(rb, board, show);
}
