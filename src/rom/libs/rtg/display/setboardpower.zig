// SPDX-License-Identifier: MPL-2.0
//! SetBoardPower: The picture shown, black, or the display asleep.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _display = @import("_display.zig");
const boards = @import("../board/_board.zig");

/// Puts a board in a power state: on, blank or asleep.
///
/// SYNOPSIS:
/// ```zig
/// fn SetBoardPower(rb: *RtgBase, board: *rtg.RtgBoard, state: u32) i32
/// ```
///
/// SINCE: 1.29. LVO -68.
///
/// INPUTS:
/// - `board` - the board.
/// - `state` - `RTGPWR_ON`: the picture shown. `RTGPWR_BLANK`: the
///   picture black, everything else running. `RTGPWR_ASLEEP`: the
///   display asleep - its backlight off, a panel's display off, a
///   monitor sent to sleep.
///
/// RESULT:
/// The state the board is in then: the one asked for, or `RTGPWR_BLANK`
/// where it was asked to sleep and its display does not sleep by itself
/// (`RTGBC_POWER` clear). Below 0, an error, and the board as it was:
/// `RTGERR_BAD_ARG` for a state there is none of, `RTGERR_NO_DISPLAY` on
/// a board whose device has gone, `RTGERR_NOT_SUPPORTED` on a board with
/// no operations, or what the driver answered.
///
/// BEHAVIOR:
/// A board starts on. The library keeps the state (`GetBoardInfo`,
/// `power`), and everything the board showed through it: what is shown,
/// drawn or moved while the board is dark is kept, and is on the glass
/// when it is put on again, with its backlight at the brightness it had
/// (`SetBoardBrightness`, which a board asleep keeps and does not
/// apply). Nobody remembers what to put back.
///
/// Blank is the library's work on every board whose picture it
/// composes: the display is delivered a black picture, and nothing of
/// what changes until the board is on again. A board whose display
/// reads its buffers of alone is put in each state by its driver; one
/// of those whose driver has no such operation is shown nothing while
/// it is dark, its buffers still marked showing. Asleep is the driver's
/// (`power`), asked once the picture is black, and undone before the
/// picture comes back.
///
/// The tasks that asked are told of a change (`AddRtgNotify`), and the
/// board's `changes` are raised. A wait for a frame of a board asleep
/// is by the clock (`WaitVBlank`).
///
/// CONTEXT:
/// - Waits: for the picture delivered or the display to take the state,
///   where the driver waits, and while another task holds the board's
///   lock.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: takes the board's lock, and inside it the board's compose
///   lock, so no picture is shown or handed on between the states. No
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
/// `SetBoardBrightness`, `GetBoardInfo`, `ShowBoard`, `AddRtgNotify`
///
/// EXAMPLES:
/// ```zig
/// // Nothing to see: the display sleeps until a key is pressed.
/// _ = rb.SetBoardPower(board, rtg.boards.RTGPWR_ASLEEP);
/// // ...
/// _ = rb.SetBoardPower(board, rtg.boards.RTGPWR_ON);
/// ```
pub fn SetBoardPower(rb: *RtgBase, board: *rtg.RtgBoard, state: u32) i32 {
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    return _display.power(rb, board, state);
}
