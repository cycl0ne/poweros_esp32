// SPDX-License-Identifier: MPL-2.0
//! RefreshBitMap: Rows y to y + rows of a buffer were written: hand
//! them to the display.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const _bitmap = @import("_bitmap.zig");

/// Hands rows of a buffer that were written on to the display.
///
/// SYNOPSIS:
/// ```zig
/// fn RefreshBitMap(_: *RtgBase, bitmap: *rtg.RtgBitMap, y: u32, rows: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -108.
///
/// INPUTS:
/// - `bitmap` - the buffer.
/// - `y` - the first row written.
/// - `rows` - how many; 0 is every row from `y` on.
///
/// RESULT:
/// `RTGERR_OK`, `RTGERR_BAD_ARG` for a buffer with no pixels or no board,
/// `RTGERR_BOUNDS` for a first row past the end, `RTGERR_NOT_SUPPORTED`
/// for a board that needs no telling, or what the driver answered.
///
/// BEHAVIOR:
/// What a caller that wrote the pixels itself calls when it has finished.
/// A board whose display reads the buffer itself needs nothing; one that
/// sends the pixels over a bus sends those rows. The rows are cut to the
/// buffer.
///
/// CONTEXT:
/// - Waits: only if the driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Forbid: must not be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocBitMap`, `ShowBitMap`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.RefreshBitMap(buffer, 10, 50);
/// ```
pub fn RefreshBitMap(_: *RtgBase, bitmap: *rtg.RtgBitMap, y: u32, rows: u32) i32 {
    if (bitmap.pixels == null) return err.RTGERR_BAD_ARG;
    if (y >= bitmap.height) return err.RTGERR_BOUNDS;
    const count = if (rows == 0) bitmap.height - y else @min(rows, bitmap.height - y);

    const board: *rtg.RtgBoard = @ptrCast(@alignCast(bitmap.board orelse return err.RTGERR_BAD_ARG));
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const refresh = ops.refresh orelse return err.RTGERR_NOT_SUPPORTED;
    return refresh(board, bitmap, y, count);
}
