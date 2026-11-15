// SPDX-License-Identifier: MPL-2.0
//! ShowBitMap: Show that buffer, its pixel (x, y) at the top left; null
//! shows nothing.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const _display = @import("_display.zig");
const boards = @import("../board/_board.zig");

/// Shows a buffer on a board's display.
///
/// SYNOPSIS:
/// ```zig
/// fn ShowBitMap(rb: *RtgBase, board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap, x: u32, y: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -100.
///
/// INPUTS:
/// - `board` - the board.
/// - `bitmap` - one of its buffers made `RTGBMF_DISPLAYABLE`, or null to
///   show nothing.
/// - `x` - the buffer's column at the display's left edge.
/// - `y` - its row at the top edge.
///
/// RESULT:
/// `RTGERR_OK`, or: `RTGERR_BAD_ARG` for another board's buffer,
/// `RTGERR_NOT_DISPLAYABLE`, `RTGERR_NOT_SUPPORTED` for a board that
/// cannot show buffers or cannot pan to a non-zero `x` or `y`, or what the
/// driver answered.
///
/// BEHAVIOR:
/// The buffers shown before - one, or several in bands - are no longer
/// marked showing, so they can be freed; the new one is, so it cannot. A display that is already showing
/// takes the new buffer up whole, at the start of a frame, and this
/// returns when it has: the one shown before is no longer read and may be
/// drawn into - which is how a program shows a frame while it draws the
/// next.
///
/// A show that fails changes nothing. On any answer but `RTGERR_OK` the
/// board goes on reading the buffers it read, they stay marked showing
/// and `BoardDisplayBitMap` answers as it did; a buffer refused that was
/// not showing is not marked, so it can be freed. The same for null: a
/// board that could not be made to show nothing goes on showing its
/// picture. On a board that is sent its picture over a bus, rows of the
/// buffer refused may have reached the glass before the send failed: a
/// row stays so until it is handed on again, and `RefreshBitMap` of the
/// buffers still shown, all their rows, puts the glass right.
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
/// Two drivers do not yet leave a failed show as nothing: the DSI boards'
/// keeps the buffer it was handed when it answers an error - no memory
/// for the stream's chain, a flip that did not land - and reads it when
/// the pointer next moves or is first laid; the RGB panel's stops its
/// stream before a start that can still fail, and the display is then
/// dark.
///
/// The `fb` driver does not look at whether an emulator's display took
/// the new picture - the ramfb's settings written, the virtio GPU's
/// commands handed over: where it did not, the show still answers
/// `RTGERR_OK`, the buffer handed over is marked showing, and the window
/// stays on the picture shown before until the next show.
///
/// SEE ALSO:
/// `BoardDisplayBitMap`, `AllocBitMap`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.ShowBitMap(board, buffer, 0, 0);
/// ```
pub fn ShowBitMap(rb: *RtgBase, board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap, x: u32, y: u32) i32 {
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const show = ops.show_bitmap orelse return err.RTGERR_NOT_SUPPORTED;

    // One show at a time on a board, the driver's and the marks together:
    // no buffer is freed, and no other picture asked for, in between.
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    if (bitmap) |bm| {
        if (bm.board != @as(?*anyopaque, @ptrCast(board))) return err.RTGERR_BAD_ARG;
        if (bm.flags & rtg.bitmaps.RTGBMF_DISPLAYABLE == 0) return err.RTGERR_NOT_DISPLAYABLE;
    }
    const code = show(board, bitmap, x, y);
    if (code != err.RTGERR_OK) return code;

    if (bitmap) |bm| _display.markShowing(board, &.{bm}, bm) else _display.markShowing(board, &.{}, null);
    return err.RTGERR_OK;
}
