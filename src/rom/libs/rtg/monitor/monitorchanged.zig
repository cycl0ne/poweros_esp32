// SPDX-License-Identifier: MPL-2.0
//! MonitorChanged: Something happened at a board's connector.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _monitor = @import("_monitor.zig");

/// Has a board's connector looked at again.
///
/// SYNOPSIS:
/// ```zig
/// fn MonitorChanged(rb: *RtgBase, board: *rtg.RtgBoard) void
/// ```
///
/// SINCE: 1.20. LVO -392.
///
/// INPUTS:
/// - `board` - the board at whose connector something happened: one of
///   the caller's own, whose ops fill in `detect`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The board is marked and the library's monitor task woken; the call
/// does no more. The task then asks the board's `detect`, keeps what the
/// monitor now there says of itself, and makes the board's modes again
/// of the timings it names that the board's `check_mode` takes - a mode
/// of the figures of one the board had keeps that mode's number. A board
/// that shows is handed the mode it is in and what it shows again
/// (`show`), with the timings the new monitor gives it, where the new
/// list has that mode; where it has not, what it showed is shown in the
/// mode the new monitor prefers, scaled by the widths, on a board that
/// scales its bands (`RTGBC_SCALE_BANDS`), and a board that does not
/// shows nothing and is in no mode until it is shown in one. The
/// board's `changes` are raised and the tasks that asked are told
/// (`AddRtgNotify`).
///
/// A driver calls it from its hot-plug interrupt, or from a task of its
/// own that looks at the port. Several calls before the task has looked
/// are one look, and a look that finds what the last one found - the same
/// monitor, or none still - changes nothing: a driver whose connector has
/// no interrupt may call it now and then. On a board without `detect` it
/// does nothing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes: a flag is written and a task signalled.
/// - Locks: none taken.
/// - Process: any, or none.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetBoardMonitor`, `AddRtgNotify`, `AddBoardMode`
///
/// EXAMPLES:
/// ```zig
/// // The hot-plug line's interrupt.
/// rb.MonitorChanged(board);
/// ```
pub fn MonitorChanged(rb: *RtgBase, board: *rtg.RtgBoard) void {
    _monitor.mark(rb, board);
}
