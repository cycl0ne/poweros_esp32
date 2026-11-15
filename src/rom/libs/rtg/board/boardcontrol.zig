// SPDX-License-Identifier: MPL-2.0
//! BoardControl: Something only this driver knows about (RTGCTRL_*), or
//! RTGCTRL_RESET_STATS, which every board takes.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const privateOf = _board.privateOf;
const _board = @import("_board.zig");

/// Asks a board something only its driver knows about.
///
/// SYNOPSIS:
/// ```zig
/// fn BoardControl(_: *RtgBase, board: *rtg.RtgBoard, what: u32, value: isize) isize
/// ```
///
/// SINCE: 1.0. LVO -68.
///
/// INPUTS:
/// - `board` - the board.
/// - `what` - an `RTGCTRL_` code: `RTGCTRL_RESET_STATS`, which every board
///   takes, or one of the driver's own.
/// - `value` - the code's argument.
///
/// RESULT:
/// `RTGERR_OK` for `RTGCTRL_RESET_STATS`. For a driver's own code what
/// the driver answered, or `RTGERR_NOT_SUPPORTED` for a code it does not
/// know or a board with no control at all.
///
/// BEHAVIOR:
/// `RTGCTRL_RESET_STATS` clears the library's own count of buffers shown
/// and is then handed to the driver, where it has a control, for the
/// counters it keeps; what the driver answers to it is not looked at.
///
/// CONTEXT:
/// - Waits: only if the driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: no spinlock may be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetBoardStats`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.BoardControl(board, rtg.boards.RTGCTRL_RESET_STATS, 0);
/// ```
pub fn BoardControl(_: *RtgBase, board: *rtg.RtgBoard, what: u32, value: isize) isize {
    if (what == rtg.boards.RTGCTRL_RESET_STATS) {
        // The library's own count, and the driver's where it keeps any:
        // every board takes this one, whatever its driver knows.
        privateOf(board).buffer_swaps = 0;
        if (board.ops) |ops| {
            if (ops.control) |control| _ = control(board, what, value);
        }
        return err.RTGERR_OK;
    }
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const control = ops.control orelse return err.RTGERR_NOT_SUPPORTED;
    return control(board, what, value);
}
