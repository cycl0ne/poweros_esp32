// SPDX-License-Identifier: MPL-2.0
//! ShowBitMapBands: several buffers on the display at once, each in a band
//! of its lines.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const _display = @import("_display.zig");

/// Shows several of a board's buffers at once, each in a band of display
/// lines.
///
/// SYNOPSIS:
/// ```zig
/// fn ShowBitMapBands(_: *RtgBase, board: *rtg.RtgBoard, bands: [*]const rtg.RtgBand, count: u32) i32
/// ```
///
/// SINCE: 1.2. LVO -232.
///
/// INPUTS:
/// - `board` - the board.
/// - `bands` - `count` bands, from the top of the display down: each a
///   buffer of the board made `RTGBMF_DISPLAYABLE` and as large as the
///   display, the display `line` its band starts at, and the display line
///   its first row sits at (`origin`, at most `line`); or, with
///   `RTGBANDF_REPEAT` in its `flags`, a buffer as wide as the display
///   and at least a row high, whose first row every line of the band
///   shows. The first band
///   starts at line 0, every other below the one before, and the last
///   runs to the display's bottom.
/// - `count` - 1 to `RTG_MAX_BANDS`.
///
/// RESULT:
/// `RTGERR_OK`, or: `RTGERR_BAD_ARG` for bands out of order, another
/// board's buffer, a buffer not the display's size, or rows a band would
/// show that its buffer has not got; `RTGERR_NOT_DISPLAYABLE`;
/// `RTGERR_NOT_SUPPORTED` for a board that can show only one buffer -
/// unless the bands are one buffer at its own origin, which is what
/// `ShowBitMap` shows; or what the driver answered.
///
/// BEHAVIOR:
/// Display line `y` of a band shows its buffer's row `y - origin`, so a
/// screen pulled down a hundred lines is a band from line 100 with its
/// origin there, and the screen behind it a band from line 0 above it.
/// A repeating band shows one row on all its lines: an empty stretch of
/// the display in a colour, from a buffer of one row.
/// Every buffer in a band is marked showing and cannot be freed; the
/// others of the board are not. `BoardDisplayBitMap` answers the last
/// band's buffer, the one at the display's bottom. A display that is
/// already showing takes the new bands up at the start of a frame, and
/// this returns when it has.
///
/// CONTEXT:
/// - Waits: for the display's next frame, where the board streams one.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: no spinlock may be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bands are read, not kept: the driver keeps its own copy. The
/// buffers stay the caller's.
///
/// NOTES:
/// What is drawn into any shown buffer is handed on by `RefreshBitMap` as
/// for one shown alone: the board knows which of its rows are on the glass.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ShowBitMap`, `BoardDisplayBitMap`, `RefreshBitMap`
///
/// EXAMPLES:
/// ```zig
/// // The front screen pulled down 120 lines, the one behind above it.
/// const bands = [_]rtg.RtgBand{
///     .{ .bitmap = behind, .line = 0, .origin = 0 },
///     .{ .bitmap = front, .line = 120, .origin = 120 },
/// };
/// _ = rb.ShowBitMapBands(board, &bands, bands.len);
/// ```
pub fn ShowBitMapBands(_: *RtgBase, board: *rtg.RtgBoard, bands: [*]const rtg.RtgBand, count: u32) i32 {
    if (count == 0 or count > rtg.RTG_MAX_BANDS) return err.RTGERR_BAD_ARG;
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const height = board.info.height;
    var shown: [rtg.RTG_MAX_BANDS]*rtg.RtgBitMap = undefined;
    for (bands[0..count], 0..) |band, i| {
        const bm = band.bitmap;
        if (bm.board != @as(?*anyopaque, @ptrCast(board))) return err.RTGERR_BAD_ARG;
        if (bm.flags & rtg.bitmaps.RTGBMF_DISPLAYABLE == 0) return err.RTGERR_NOT_DISPLAYABLE;
        const repeat = band.flags & rtg.RTGBANDF_REPEAT != 0;
        if (bm.width != board.info.width) return err.RTGERR_BAD_ARG;
        if (if (repeat) bm.height == 0 else bm.height != height) return err.RTGERR_BAD_ARG;
        if (i == 0 and band.line != 0) return err.RTGERR_BAD_ARG;
        if (i > 0 and band.line <= bands[i - 1].line) return err.RTGERR_BAD_ARG;
        if (band.line >= height or band.origin > band.line) return err.RTGERR_BAD_ARG;
        // The band's last line shows a row the buffer has.
        const end = if (i + 1 < count) bands[i + 1].line else height;
        if (!repeat and end - band.origin > bm.height) return err.RTGERR_BAD_ARG;
        shown[i] = bm;
    }
    const code = if (ops.show_bands) |show|
        show(board, bands, count)
    else if (count == 1 and bands[0].origin == 0 and bands[0].flags == 0)
        (ops.show_bitmap orelse return err.RTGERR_NOT_SUPPORTED)(board, bands[0].bitmap, 0, 0)
    else
        return err.RTGERR_NOT_SUPPORTED;
    if (code != err.RTGERR_OK) return code;
    _display.markShowing(board, shown[0..count], shown[count - 1]);
    return err.RTGERR_OK;
}
