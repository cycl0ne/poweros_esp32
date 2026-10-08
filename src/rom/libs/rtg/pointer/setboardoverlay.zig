// SPDX-License-Identifier: MPL-2.0
//! SetBoardOverlay: the image a board lays over its picture under the
//! pointer - a dragged icon - made once in the board's own pixel format,
//! its coverage dithered into a mask.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const setboardpointer = @import("setboardpointer.zig");

/// Gives a board a second image to lay over its picture, under the
/// pointer, which from then on follows the pointer.
///
/// SYNOPSIS:
/// ```zig
/// fn SetBoardOverlay(rb: *RtgBase, board: *rtg.RtgBoard, image: ?*const rtg.Surface, hot_x: u32, hot_y: u32) i32
/// ```
///
/// SINCE: 1.3. LVO -236.
///
/// INPUTS:
/// - `board` - the board.
/// - `image` - a surface in `rgba32`, `bgra32` or `argb1555`, at most
///   `RTG_OVERLAY_MAX` pixels each way; null takes the overlay away.
/// - `hot_x`, `hot_y` - the pixel of the image that is its point, inside
///   it: the one that sits at the pointer's point.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_NOT_SUPPORTED` for a board without
/// `RTGBC_OVERLAY`; `RTGERR_BAD_FORMAT` for an image with no alpha, or a
/// board whose format a pixel is not whole bytes of; `RTGERR_BAD_ARG` for
/// an image too large, empty, or with its point outside it;
/// `RTGERR_NO_MEMORY`; or what the driver answered. On any failure the
/// board keeps the overlay it had.
///
/// BEHAVIOR:
/// The image is converted here and not again, as SetBoardPointer's is:
/// every pixel into the board's format, and its coverage into a mask of
/// one bit a pixel - dithered by a 4x4 ordered pattern rather than cut in
/// half, so a soft edge, a shadow or an image made see-through keeps its
/// look as a pattern of dots. The board lays it over the picture on the
/// way to the glass, under the pointer, the picture never holding it; it
/// is shown whether the pointer is or not, so a finger dragging on a
/// touch panel, where the pointer is hidden, sees it. Its point is put at
/// the pointer's, and it follows the pointer's moves until
/// `MoveBoardOverlay` puts it somewhere of its own.
///
/// CONTEXT:
/// - Waits: for rtg's pointer lock while another task moves the pointer,
///   and for a driver that sends the rows over a bus.
/// - Interrupts: no. It allocates.
/// - Locks: takes rtg's pointer lock while the driver changes images; no
///   spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's image is read and not kept. The converted one is the
/// library's - in internal memory for a driver whose interrupts read it -
/// freed by the next SetBoardOverlay or by DeleteBoard.
///
/// NOTES:
/// intuition's `BeginDrag` and `EndDrag` are how a program drags: they
/// set the overlay on the right board and take it away again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MoveBoardOverlay`, `SetBoardPointer`, `MoveBoardPointer`
///
/// EXAMPLES:
/// ```zig
/// if (rb.SetBoardOverlay(board, &icon_surface, 24, 24) == rtg.errors.RTGERR_OK) {
///     // ... the pointer moves; the icon with it ...
///     _ = rb.SetBoardOverlay(board, null, 0, 0);
/// }
/// ```
pub fn SetBoardOverlay(rb: *RtgBase, board: *rtg.RtgBoard, image: ?*const rtg.Surface, hot_x: u32, hot_y: u32) i32 {
    const sys = rb.sys_base;
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    if (board.info.caps & rtg.boards.RTGBC_OVERLAY == 0) return err.RTGERR_NOT_SUPPORTED;
    const set_overlay = ops.set_overlay.?;
    const move_overlay = ops.move_overlay.?;

    const made: ?*rtg.RtgPointerImage = if (image) |source| blk: {
        const converted = setboardpointer.convert(rb, board, source, hot_x, hot_y, rtg.boards.RTG_OVERLAY_MAX, .dither);
        if (converted.code != err.RTGERR_OK) return converted.code;
        break :blk converted.image;
    } else null;

    sys.ObtainSemaphore(&rb.pointer_lock);
    // Placed before it is shown: the driver lays it where it belongs from
    // its first frame.
    board.overlay_x = board.pointer_x;
    board.overlay_y = board.pointer_y;
    board.overlay_follows = 1;
    if (made) |now| move_overlay(board, board.overlay_x - @as(i32, @intCast(now.hot_x)), board.overlay_y - @as(i32, @intCast(now.hot_y)));
    const code = set_overlay(board, made);
    if (code != err.RTGERR_OK) {
        sys.ReleaseSemaphore(&rb.pointer_lock);
        if (made) |gone| sys.FreeVec(gone);
        return code;
    }
    const old = board.overlay;
    board.overlay = made;
    sys.ReleaseSemaphore(&rb.pointer_lock);
    // The driver has let go of the old one: set_overlay returned.
    if (old) |gone| sys.FreeVec(gone);
    return err.RTGERR_OK;
}
