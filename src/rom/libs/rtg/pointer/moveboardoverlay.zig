// SPDX-License-Identifier: MPL-2.0
//! MoveBoardOverlay: the overlay put somewhere of its own.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const composer = @import("../compose/_compose.zig");

/// Puts the overlay's point at (x, y), and from then on keeps it there
/// rather than with the pointer.
///
/// SYNOPSIS:
/// ```zig
/// fn MoveBoardOverlay(rb: *RtgBase, board: *rtg.RtgBoard, x: i32, y: i32) void
/// ```
///
/// SINCE: 1.3. LVO -240.
///
/// INPUTS:
/// - `board` - the board.
/// - `x`, `y` - where the overlay's point goes, in the coordinates a
///   caller draws in. Anywhere: the part of the image off the picture is
///   not shown.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The overlay stops following the pointer and stands at (x, y) until it
/// is moved again or `SetBoardOverlay` gives it a new image, which makes
/// it follow the pointer once more. A board without an overlay keeps the
/// place for one set later. Nothing is done for the same place twice.
///
/// CONTEXT:
/// - Waits: for the board's compose lock while another task moves the
///   pointer or hands on what it drew, and on a board that sends rows
///   over a bus, for that. From a task, never from an input handler.
/// - Interrupts: no.
/// - Locks: takes the board's compose lock, a semaphore; no spinlock may
///   be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// How a dragged icon that was not taken flies back to where it came
/// from, a step at a time.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetBoardOverlay`, `MoveBoardPointer`
///
/// EXAMPLES:
/// ```zig
/// rb.MoveBoardOverlay(board, start_x, start_y);
/// ```
pub fn MoveBoardOverlay(rb: *RtgBase, board: *rtg.RtgBoard, x: i32, y: i32) void {
    composer.moveOverlay(rb, board, x, y);
}
