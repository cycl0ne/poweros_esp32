// SPDX-License-Identifier: MPL-2.0
//! FreeBitMap: Give a buffer back.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const bm_flags = rtg.bitmaps;
const _bitmap = @import("_bitmap.zig");

/// Gives a buffer back.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeBitMap(rb: *RtgBase, bitmap: ?*rtg.RtgBitMap) void
/// ```
///
/// SINCE: 1.0. LVO -96.
///
/// INPUTS:
/// - `bitmap` - the buffer. Null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Display memory the library allocated goes back to the board; memory
/// `AttachBitMap` was given stays the caller's. A buffer the board is
/// showing is refused, with `RTGERR_IN_USE` in `RtgLastError`; it stays
/// the caller's, to free once another is shown.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It frees memory.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The handle is gone, and the board's memory with it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocBitMap`, `AttachBitMap`, `ShowBitMap`
///
/// EXAMPLES:
/// ```zig
/// rb.FreeBitMap(buffer);
/// ```
pub fn FreeBitMap(rb: *RtgBase, bitmap: ?*rtg.RtgBitMap) void {
    const freed = bitmap orelse return;
    const sys = rb.sys_base;
    // What the board is reading is not the caller's to take away.
    if (freed.flags & bm_flags.RTGBMF_SHOWING != 0) {
        rb.last_error = rtg.errors.RTGERR_IN_USE;
        return;
    }
    const board: ?*rtg.RtgBoard = @ptrCast(@alignCast(freed.board));
    if (board) |b| {
        sys.Remove(&freed.node);
        if (freed.flags & bm_flags.RTGBMF_BOARD_MEMORY != 0 and freed.pixels != null) {
            boards.privateOf(b).arena.free(sys, freed.offset, freed.taken);
        }
    }
    sys.FreeVec(freed);
}
