// SPDX-License-Identifier: MPL-2.0
//! SetBoardBrightness: The backlight, 0 to 100, the right way round
//! whatever the part does.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const boards = @import("../board/_board.zig");

/// Sets the brightness of a board's backlight.
///
/// SYNOPSIS:
/// ```zig
/// fn SetBoardBrightness(rb: *RtgBase, board: *rtg.RtgBoard, percent: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -120.
///
/// INPUTS:
/// - `board` - the board.
/// - `percent` - 0 to 100; more is 100.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_NOT_SUPPORTED` on a board with no backlight to
/// set (`RTGBC_BRIGHTNESS` clear); or what the driver answered, and the
/// brightness as it was.
///
/// BEHAVIOR:
/// 0 is dark and 100 is full, whichever way round the part itself
/// counts. A backlight that is a line on or off (`brightness_steps` 2 in
/// `GetBoardInfo`) is on for anything above 0. The library keeps the
/// value: `GetBoardInfo` answers it (`brightness`), and a board that was
/// asleep comes back with it. On a board that is asleep it is kept and
/// not applied until the board wakes (`SetBoardPower`).
///
/// A panel's backlight is lit with its board's first picture, at what
/// its device's tags ask (`RTGA_Brightness`), else in full; a brightness
/// set before that is applied at once, and the first picture leaves it.
///
/// A monitor on a connector (`RTGBF_CONNECTOR`) keeps a brightness of
/// its own, and it is left as the monitor has it: nothing sets it but
/// this call and a brightness its device's tags ask. Until one of them
/// has, `brightness` in `GetBoardInfo` says 100, whatever the monitor
/// is set to.
///
/// Dimmed is not asleep: `SetBoardPower` is what puts a display to
/// sleep.
///
/// CONTEXT:
/// - Waits: only if the driver does, and while another task holds the
///   board's lock.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: takes the board's lock. No spinlock may be held: a driver
///   may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetBoardInfo`, `SetBoardPower`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.SetBoardBrightness(board, 60);
/// ```
pub fn SetBoardBrightness(rb: *RtgBase, board: *rtg.RtgBoard, percent: u32) i32 {
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    if (board.info.caps & rtg.boards.RTGBC_BRIGHTNESS == 0) return err.RTGERR_NOT_SUPPORTED;
    const want = @min(percent, 100);
    // A board asleep has its backlight off: it wakes with this.
    if (board.info.power != rtg.boards.RTGPWR_ASLEEP) {
        const code = board.ops.?.set_brightness.?(board, want);
        if (code != err.RTGERR_OK) return code;
    }
    board.info.brightness = want;
    boards.privateOf(board).lit = true;
    return err.RTGERR_OK;
}
