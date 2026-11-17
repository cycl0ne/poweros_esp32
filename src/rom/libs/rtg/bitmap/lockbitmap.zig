// SPDX-License-Identifier: MPL-2.0
//! LockBitMap: Hold off the picture a flipped board makes of a buffer.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const flips = @import("../compose/_flip.zig");

/// Holds off the picture a flipped board makes of its buffers, until
/// `UnlockBitMap`.
///
/// SYNOPSIS:
/// ```zig
/// fn LockBitMap(rb: *RtgBase, bitmap: *rtg.RtgBitMap) void
/// ```
///
/// SINCE: 1.32. LVO -96.
///
/// INPUTS:
/// - `bitmap` - the buffer about to be written in, of a board.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A board that is flipped between frames makes each picture from the
/// buffers it shows, starting at the top. A picture written into a
/// shown buffer all at once - a window's next frame copied whole - would
/// be fetched half new and half old where the two meet. Between this
/// call and `UnlockBitMap` no picture is fetched from the board's
/// buffers: what is written in between is on the glass whole or not at
/// all. A fetch under way is waited for first.
///
/// On a board that is not flipped, and for a buffer of no board, nothing
/// is held and nothing waited for: the display reads the buffer as it
/// is. The two calls nest for one task, an unlock for each lock.
///
/// It is for a writer of whole rectangles that is not the board's
/// engine: `CopyRect` and `CopyRects` hold the picture off themselves.
/// It is not needed around drawing that is handed on with `RefreshRect`
/// a piece at a time.
///
/// CONTEXT:
/// - Waits: yes, while a picture is fetched from the board's buffers.
/// - Interrupts: no.
/// - Locks: takes the board's read lock, a semaphore, held until
///   `UnlockBitMap`. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The lock is the calling task's, to give back
/// with `UnlockBitMap` on the same buffer.
///
/// NOTES:
/// No picture is made while the lock is held: hold it for the copy
/// alone, never across a wait.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UnlockBitMap`, `CopyRects`, `RefreshRect`
///
/// EXAMPLES:
/// ```zig
/// rb.LockBitMap(display);
/// copyFrame(display, frame);
/// rb.UnlockBitMap(display);
/// _ = rb.RefreshRect(display, null);
/// ```
pub fn LockBitMap(rb: *RtgBase, bitmap: *rtg.RtgBitMap) void {
    const board: *rtg.RtgBoard = @ptrCast(@alignCast(bitmap.board orelse return));
    flips.holdWrite(rb, board);
}
