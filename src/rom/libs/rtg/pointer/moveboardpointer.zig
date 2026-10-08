// SPDX-License-Identifier: MPL-2.0
//! MoveBoardPointer: where the pointer's point is.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;

/// Puts the pointer's point at a place on the picture.
///
/// SYNOPSIS:
/// ```zig
/// fn MoveBoardPointer(rb: *RtgBase, board: *rtg.RtgBoard, x: i32, y: i32) void
/// ```
///
/// SINCE: 1.1. LVO -224.
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
/// A board that turns its picture itself (`MirrorBoard`, `SwapBoardAxes`,
/// `SetBoardGap`) turns the pointer with it: the driver lays the pointer
/// into the picture's own order on its way out, before the turn.
///
/// CONTEXT:
/// - Waits: for the pointer's lock while another task changes the pointer,
///   and on a board that sends the rows the pointer left over a bus, for
///   that. Made to be called on every pointer event - from a task, never
///   from an input handler, which may not wait.
/// - Interrupts: no. A driver may send the rows the pointer left over a
///   bus.
/// - Locks: takes rtg's pointer lock, a semaphore, for the moment it takes the
///   driver to move it; no spinlock may be held.
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
    const sys = rb.sys_base;
    sys.ObtainSemaphore(&rb.pointer_lock);
    defer sys.ReleaseSemaphore(&rb.pointer_lock);
    if (board.pointer_x == x and board.pointer_y == y) return;
    board.pointer_x = x;
    board.pointer_y = y;
    const ops = board.ops orelse return;
    if (board.overlay_follows != 0) {
        board.overlay_x = x;
        board.overlay_y = y;
        if (board.overlay) |overlay| if (ops.move_overlay) |move_overlay| {
            move_overlay(board, x - @as(i32, @intCast(overlay.hot_x)), y - @as(i32, @intCast(overlay.hot_y)));
        };
    }
    const image = board.pointer orelse return;
    const move_pointer = ops.move_pointer orelse return;
    move_pointer(board, x - @as(i32, @intCast(image.hot_x)), y - @as(i32, @intCast(image.hot_y)));
}
