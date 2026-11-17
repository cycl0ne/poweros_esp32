// SPDX-License-Identifier: MPL-2.0
//! MoveBoardPointer: where the pointer's point is.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const composer = @import("../compose/_compose.zig");

/// Puts the pointer's point at a place on the picture.
///
/// SYNOPSIS:
/// ```zig
/// fn MoveBoardPointer(rb: *RtgBase, board: *rtg.RtgBoard, x: i32, y: i32) void
/// ```
///
/// SINCE: 1.1. LVO -144.
///
/// INPUTS:
/// - `board` - the board.
/// - `x`, `y` - where the point goes, in the coordinates a caller draws
///   in. Anywhere: the part of the image off the picture is not shown.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The position is kept whether or not the board has a pointer, an image
/// or the pointer shown, so an image set or shown later appears where the
/// pointer is. The image's point is put here, which is its hot spot and
/// not its corner. Nothing is done for the same place twice. An overlay
/// that follows the pointer (SetBoardOverlay) moves with it.
///
/// A picture that is mirrored (`MirrorBoard`) has its pointer mirrored
/// with it: the place is the picture's own, and the pointer is laid
/// into the picture's own order on its way out, before the turn.
///
/// On a board whose picture the library composes, a move is the
/// rectangle the image left and the one it came to, delivered again - one
/// rectangle where the two touch: it costs the image's size, not the
/// picture's.
///
/// CONTEXT:
/// - Waits: for the board's compose lock while another task changes the
///   pointer or hands on what it drew, and on a board that sends the
///   rows the pointer left over a bus, for that. Made to be called on
///   every pointer event - from a task, never from an input handler,
///   which may not wait.
/// - Interrupts: no. A driver may send the rows the pointer left over a
///   bus.
/// - Locks: takes the board's compose lock, a semaphore, for as long as
///   the move takes; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetBoardPointer`, `ShowBoardPointer`
///
/// EXAMPLES:
/// ```zig
/// rb.MoveBoardPointer(board, event.x, event.y);
/// ```
pub fn MoveBoardPointer(rb: *RtgBase, board: *rtg.RtgBoard, x: i32, y: i32) void {
    composer.movePointer(rb, board, x, y);
}
