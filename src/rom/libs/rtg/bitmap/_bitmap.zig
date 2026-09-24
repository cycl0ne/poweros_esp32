// SPDX-License-Identifier: MPL-2.0
//! Buffers out of a board's display memory.
//!
//! AllocBitMap cuts a piece off the board's memory and describes it;
//! AttachBitMap describes memory the caller already has. Either way what
//! comes back is a buffer whose first seven fields are a drawing surface,
//! so whoever draws into it needs to know nothing about boards.
//!
//! Writing into a buffer is the caller's business. RefreshBitMap is how it
//! says it has finished a stretch of rows, and that is the call that
//! reaches the board: for memory the CPU holds in its cache the board has
//! to be told, and for a display on a bus the rows have to be sent.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const err = rtg.errors;
const bm_flags = rtg.bitmaps;

const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");

/// The buffer a node of a board's buffer list belongs to.
///
/// INPUTS:
/// - `node` - the buffer's node.
fn bitmapOf(node: *exec.Node) *rtg.RtgBitMap {
    return @fieldParentPtr("node", node);
}

/// Every buffer of a board, when the board itself is going.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board.
pub fn freeAll(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const rtg_lib = rb.iface();
    var node = board.bitmaps.first();
    while (node) |n| {
        const next = n.next();
        const bitmap = bitmapOf(n);
        bitmap.flags &= ~bm_flags.RTGBMF_SHOWING;
        rtg_lib.FreeBitMap(bitmap);
        node = next;
    }
}

/// Is any buffer of this board one that will not give its memory up? Those
/// are what stops a mode change.
///
/// INPUTS:
/// - `board` - the board.
pub fn anyFixed(board: *rtg.RtgBoard) bool {
    var node = board.bitmaps.first();
    while (node) |n| : (node = n.next()) {
        const bitmap = bitmapOf(n);
        if (bitmap.flags & bm_flags.RTGBMF_BOARD_MEMORY == 0) continue;
        if (bitmap.flags & bm_flags.RTGBMF_VOLATILE == 0) return true;
    }
    return false;
}

/// Take the memory from every buffer that agreed to lose it. The handle
/// stays the caller's and stays valid; it has no pixels until it is freed
/// and allocated again.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board.
pub fn emptyVolatile(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const sys = rb.sys_base;
    const private = boards.privateOf(board);
    var node = board.bitmaps.first();
    while (node) |n| : (node = n.next()) {
        const bitmap = bitmapOf(n);
        if (bitmap.flags & bm_flags.RTGBMF_BOARD_MEMORY == 0) continue;
        if (bitmap.pixels != null) private.arena.free(sys, bitmap.offset, bitmap.taken);
        bitmap.pixels = null;
        bitmap.size_bytes = 0;
        bitmap.taken = 0;
        bitmap.flags &= ~bm_flags.RTGBMF_VOLATILE;
    }
}
