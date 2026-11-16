// SPDX-License-Identifier: MPL-2.0
//! FrameDone: A frame of a board's display ended.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const _frame = @import("_frame.zig");

/// Says that a frame of a board's display ended.
///
/// SYNOPSIS:
/// ```zig
/// fn FrameDone(rb: *RtgBase, board: *rtg.RtgBoard) void
/// ```
///
/// SINCE: 1.22. LVO -340.
///
/// INPUTS:
/// - `board` - the board whose display ended a frame: one of the
///   caller's own.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The frame is counted (`RtgBoardStats.blanks`), and every task that
/// waits for frames of the board (`WaitVBlank`) is counted one frame on
/// and signalled when its count is reached. From the first call on the
/// board is one that says its frames (`RTGBC_VBLANK`): a wait is for
/// them, with a limit, and no longer by the clock.
///
/// A driver calls it once a frame, from the interrupt that says the
/// frame ended - the blanking's, or the one that starts the next
/// picture. A driver without such an interrupt does not call it, and
/// its board is waited for by the clock.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes. That is where it is called.
/// - Locks: none taken. The count and the walk of the waiters are inside
///   Disable, which an interrupt is in already.
/// - Process: any, or none.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WaitVBlank`, `GetBoardStats`, `MonitorChanged`
///
/// EXAMPLES:
/// ```zig
/// // The frame interrupt's server.
/// panel.rtg_base.FrameDone(panel.board);
/// ```
pub fn FrameDone(rb: *RtgBase, board: *rtg.RtgBoard) void {
    _frame.done(rb.sys_base, &boards.privateOf(board).frames);
}
