// SPDX-License-Identifier: MPL-2.0
//! UnlockBitMap: Let a flipped board make pictures of a buffer again.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const flips = @import("../compose/_flip.zig");

/// Lets a flipped board make pictures of its buffers again, after
/// `LockBitMap`.
///
/// SYNOPSIS:
/// ```zig
/// fn UnlockBitMap(rb: *RtgBase, bitmap: *rtg.RtgBitMap) void
/// ```
///
/// SINCE: 1.32. LVO -152.
///
/// INPUTS:
/// - `bitmap` - the buffer `LockBitMap` was called with.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Gives back what `LockBitMap` took: the board's next picture is made
/// of the buffers as they are now. Nothing is handed on by it - what
/// was written is told the board with `RefreshRect`, as ever.
///
/// On a board that is not flipped, and for a buffer of no board, it does
/// nothing, as `LockBitMap` did.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: gives the board's read lock back. Only the task that called
///   `LockBitMap` may call it, once for each.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated or freed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockBitMap`, `RefreshRect`
///
/// EXAMPLES:
/// ```zig
/// rb.LockBitMap(display);
/// copyFrame(display, frame);
/// rb.UnlockBitMap(display);
/// ```
pub fn UnlockBitMap(rb: *RtgBase, bitmap: *rtg.RtgBitMap) void {
    const board: *rtg.RtgBoard = @ptrCast(@alignCast(bitmap.board orelse return));
    flips.letWrite(rb, board);
}
