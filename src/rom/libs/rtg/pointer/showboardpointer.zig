// SPDX-License-Identifier: MPL-2.0
//! ShowBoardPointer: the pointer laid over the picture, or not.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;

/// Shows a board's pointer, or hides it.
///
/// SYNOPSIS:
/// ```zig
/// fn ShowBoardPointer(rb: *RtgBase, board: *rtg.RtgBoard, show: bool) i32
/// ```
///
/// SINCE: 1.1. LVO -228.
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
/// The picture itself never holds the pointer: the board lays it in on
/// the way to the glass, so hiding it leaves the picture exactly as it was
/// drawn. Shown with no image set, nothing appears until one is.
/// `RTGBF_POINTER` in `RtgBoardInfo.flags` says which it is.
///
/// CONTEXT:
/// - Waits: for rtg's pointer lock while another task changes the pointer,
///   and for a driver that sends the pointer's rows over a bus.
/// - Interrupts: no. A driver may send the pointer's rows over a bus.
/// - Locks: takes rtg's pointer lock while the driver changes it; no spinlock
///   may be held.
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
    const sys = rb.sys_base;
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    if (board.info.caps & rtg.boards.RTGBC_POINTER == 0) return err.RTGERR_NOT_SUPPORTED;
    const shown = board.info.flags & rtg.boards.RTGBF_POINTER != 0;
    if (shown == show) return err.RTGERR_OK;
    sys.ObtainSemaphore(&rb.pointer_lock);
    defer sys.ReleaseSemaphore(&rb.pointer_lock);
    const code = ops.show_pointer.?(board, show);
    if (code != err.RTGERR_OK) return code;
    if (show) board.info.flags |= rtg.boards.RTGBF_POINTER else board.info.flags &= ~rtg.boards.RTGBF_POINTER;
    return err.RTGERR_OK;
}
