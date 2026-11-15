// SPDX-License-Identifier: MPL-2.0
//! FreeBitMap: Give a buffer back.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const bm_flags = rtg.bitmaps;

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
/// showing is refused, and nothing says so but its `RTGBMF_SHOWING`,
/// still set: it stays the caller's, to free once another is shown.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the board's lock - through a
///   show, which may last a frame.
/// - Interrupts: no. It frees memory.
/// - Locks: takes the board's lock around its list of buffers and its
///   display memory. No spinlock may be held.
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
    const board: ?*rtg.RtgBoard = @ptrCast(@alignCast(freed.board));
    if (board) |owner| {
        // Under the board's lock, so a show that is marking this buffer
        // has either marked it or will not find it.
        boards.obtain(rb, owner);
        defer boards.release(rb, owner);
        // What the board is reading is not the caller's to take away.
        if (freed.flags & bm_flags.RTGBMF_SHOWING != 0) return;
        sys.Remove(&freed.node);
        if (freed.flags & bm_flags.RTGBMF_BOARD_MEMORY != 0 and freed.pixels != null) {
            boards.privateOf(owner).arena.give(sys, freed.offset, freed.taken);
        }
    } else if (freed.flags & bm_flags.RTGBMF_SHOWING != 0) {
        return;
    }
    sys.FreeVec(freed);
}
