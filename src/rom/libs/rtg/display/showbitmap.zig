// SPDX-License-Identifier: MPL-2.0
//! ShowBitMap: Show that buffer, whole, in the mode the board is in; null
//! shows nothing.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _display = @import("_display.zig");
const boards = @import("../board/_board.zig");

/// Shows a buffer on a board's display.
///
/// SYNOPSIS:
/// ```zig
/// fn ShowBitMap(rb: *RtgBase, board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap) i32
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// - `board` - the board.
/// - `bitmap` - one of its buffers made `RTGBMF_DISPLAYABLE`, in the
///   format and of the size of the mode the board is in - of any size on
///   a board that scales its bands (`RTGBC_SCALE_BANDS`), where it is
///   shown scaled to the display's width - or null to show nothing.
///
/// RESULT:
/// `RTGERR_OK`, or what `ShowBoard` answers for that one buffer from the
/// display's top: `RTGERR_BAD_ARG` for another board's buffer or one with
/// no pixels, `RTGERR_NOT_DISPLAYABLE`, `RTGERR_BAD_FORMAT`,
/// `RTGERR_NO_DISPLAY` for a buffer on a board whose device has gone,
/// `RTGERR_NO_MODE` on a board with no mode, `RTGERR_NOT_SUPPORTED` for a
/// board that shows nothing, or what the driver answered.
///
/// BEHAVIOR:
/// It is `ShowBoard` with the mode kept and one band: the buffer, its
/// first row at the display's top. A board that is in no mode yet is put
/// in its default with it. The buffers shown before - one, or several in
/// bands - are no longer marked showing, so they can be freed; the new one
/// is, so it cannot. A display that is already showing takes the new
/// buffer up whole, at the start of a frame, and this returns when it
/// has: the one shown before is no longer read and may be drawn into -
/// which is how a program shows a frame while it draws the next.
///
/// A show that fails changes nothing, as `ShowBoard` has it. The same for
/// null: a board that could not be made to show nothing goes on showing
/// its picture.
///
/// CONTEXT:
/// - Waits: for the display's next frame, where the board streams one,
///   and while another task holds the board's lock.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: takes the board's lock around the driver's show and the marks
///   on the board's buffers, so two shows of one board follow each other.
///   No spinlock may be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The buffer stays the caller's.
///
/// BUGS:
/// `ShowBoard`'s BUGS has what a driver does not keep yet.
///
/// SEE ALSO:
/// `ShowBoard`, `BoardDisplayBitMap`, `AllocBitMap`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.ShowBitMap(board, buffer);
/// ```
pub fn ShowBitMap(rb: *RtgBase, board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap) i32 {
    // One show at a time on a board, the driver's and the marks together.
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    const whole = bitmap orelse return _display.show(rb, board, null, &.{});
    const code = _display.show(rb, board, null, &.{.{ .bitmap = whole }});
    // The first picture is what the backlight is lit with.
    if (code == rtg.errors.RTGERR_OK) _display.light(rb, board);
    return code;
}
