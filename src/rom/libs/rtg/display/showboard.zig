// SPDX-License-Identifier: MPL-2.0
//! ShowBoard: Put the board in a mode and show bands of buffers in it,
//! as one step.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const _display = @import("_display.zig");
const boards = @import("../board/_board.zig");
const modes = @import("../mode/_mode.zig");

/// Puts a board in a mode and shows buffers in it, each in a band of
/// display lines.
///
/// SYNOPSIS:
/// ```zig
/// fn ShowBoard(rb: *RtgBase, board: *rtg.RtgBoard, mode_id: u32, bands: ?[*]const rtg.RtgBand, count: u32) i32
/// ```
///
/// SINCE: 1.21. LVO -244.
///
/// INPUTS:
/// - `board` - the board.
/// - `mode_id` - the number of the mode to put it in, as `FindBoardMode`,
///   `BestBoardMode` and `GetBoardModes` answer it; 0 keeps the mode it is
///   in, or takes its default where it is in none.
/// - `bands` - `count` bands, from the top of the display down: each a
///   buffer of the board made `RTGBMF_DISPLAYABLE`, in the mode's format
///   and as large as the mode, the display `line` its band starts at, and
///   the display line its first row sits at (`origin`, at most `line`);
///   or, with `RTGBANDF_REPEAT` in its `flags`, a buffer as wide as the
///   mode and at least a row high, whose first row every line of the band
///   shows. On a board that scales its bands (`RTGBC_SCALE_BANDS`) a
///   buffer may be of any size. The first band starts at line 0, every
///   other below the one before, and the last runs to the display's
///   bottom. Null with a `count` of 0.
/// - `count` - 0 to `RTG_MAX_BANDS`; 0 shows nothing.
///
/// RESULT:
/// `RTGERR_OK`, or: `RTGERR_BAD_MODE` for a number the board has no mode
/// of now; `RTGERR_NO_MODE` on a board with no mode; `RTGERR_BAD_ARG` for
/// more bands than a display shows, bands out of order, another board's
/// buffer or a buffer with no pixels; `RTGERR_NOT_DISPLAYABLE` for a
/// buffer that was not made to be shown, and for one that is not the
/// mode's size on a board that scales no bands; `RTGERR_BAD_FORMAT` for
/// one not in the mode's format, and for bands the library would compose
/// in a format whose pixels are not whole bytes; `RTGERR_NO_DISPLAY` on a
/// board whose device has gone; `RTGERR_NOT_SUPPORTED` for a board that
/// shows nothing, or bands on one that shows only a whole buffer
/// (`RTGBC_BANDS`); or what the driver answered.
///
/// BEHAVIOR:
/// The mode and what is shown in it change together. Display line `y` of
/// a band shows its buffer's row `y - origin`, so a screen pulled down a
/// hundred lines is a band from line 100 with its origin there, and the
/// screen behind it a band from line 0 above it. A band whose buffer is
/// not the mode's width is shown scaled, by the ratio of the mode's width
/// to the buffer's, both ways the same: it fills the display's width,
/// line `y` shows the buffer's row `(y - origin) * buffer width / mode
/// width`, and neighbouring pixels are mixed where the mode's width is
/// not a whole number of the buffer's. A line whose row the buffer has
/// not got is black. A repeating band shows
/// one row on all its lines: an empty stretch of the display in a colour,
/// from a buffer of one row. Every buffer in a band is marked showing and
/// cannot be freed; the others of the board are not. `BoardDisplayBitMap`
/// answers the last band's buffer, the one at the display's bottom. A
/// display that is already showing takes the new bands up at the start of
/// a frame, and this returns when it has.
///
/// A buffer is not touched by a mode change: every buffer of the board
/// keeps its memory, and one of another size is shown again by showing it
/// in the mode of its size. What the board says of itself follows the
/// mode (`GetBoardInfo`), and the tasks that asked are told
/// (`AddRtgNotify`).
///
/// A show that fails changes nothing: on any answer but `RTGERR_OK` the
/// board is in the mode it was in and shows what it showed, marked as it
/// was, and a buffer of the bands refused that was not showing is not
/// marked, so it can be freed. For another mode the driver may have to be
/// asked for what was shown again; where it then cannot show that either,
/// the board is in no mode and shows nothing, and says so. On a board
/// that is sent its picture over a bus, rows of a buffer refused may have
/// reached the glass before the send failed: a row stays so until it is
/// handed on again.
///
/// CONTEXT:
/// - Waits: for the display's next frame, where the board streams one,
///   for a link to come up where the mode changes, and while another task
///   holds the board's lock.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: takes the board's lock around the checks, the driver's show
///   and the marks on the board's buffers, so two shows of one board
///   follow each other, and inside it the board's compose lock, so
///   nothing is handed on and no pointer moved between the old picture
///   and the new. No spinlock may be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bands are read, not kept: the library keeps its own copy. The
/// buffers stay the caller's.
///
/// NOTES:
/// What is drawn into any shown buffer is handed on by `RefreshRect` as
/// for one shown alone: the library knows which of its rows are on the
/// glass.
///
/// How the bands reach the glass is the board's: a display that reads
/// buffers itself reads as many bands as it can, and one with a picture
/// of its own is delivered the picture the library composes of them. A
/// board that has both ways reads the buffers itself for as long as
/// nothing lies over the picture - no more bands than it reads, none
/// the library scales, no overlay, no pointer the library lays.
///
/// A band of another size is scaled by the library where it composes
/// the board's picture, and read as it is by a display whose planes
/// scale (`RTGBF_SCALES`). What is written into such a buffer is handed
/// on as into any other, and reaches the glass scaled.
///
/// BUGS:
/// The DSI boards' driver keeps the bands it was handed when it answers
/// an error - no memory for the stream's chain, a flip that did not land
/// - and reads them when the pointer next moves or is first laid.
///
/// SEE ALSO:
/// `ShowBitMap`, `BoardDisplayBitMap`, `BestBoardMode`, `RefreshRect`
///
/// EXAMPLES:
/// ```zig
/// // The front screen pulled down 120 lines, the one behind above it.
/// const bands = [_]rtg.RtgBand{
///     .{ .bitmap = behind, .line = 0, .origin = 0 },
///     .{ .bitmap = front, .line = 120, .origin = 120 },
/// };
/// _ = rb.ShowBoard(board, 0, &bands, bands.len);
/// ```
pub fn ShowBoard(rb: *RtgBase, board: *rtg.RtgBoard, mode_id: u32, bands: ?[*]const rtg.RtgBand, count: u32) i32 {
    if (count > rtg.RTG_MAX_BANDS) return err.RTGERR_BAD_ARG;
    const shown: []const rtg.RtgBand = if (bands) |given| given[0..count] else &.{};
    if (shown.len != count) return err.RTGERR_BAD_ARG;
    // The mode, the bands and the marks on the board's buffers are one
    // step: no buffer is freed, and no other picture asked for, in
    // between.
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    var wanted: ?*modes.Record = null;
    if (mode_id != 0) wanted = modes.byId(board, mode_id) orelse return err.RTGERR_BAD_MODE;
    const code = _display.show(rb, board, wanted, shown);
    // The first picture is what the backlight is lit with.
    if (code == err.RTGERR_OK) _display.light(rb, board);
    return code;
}
