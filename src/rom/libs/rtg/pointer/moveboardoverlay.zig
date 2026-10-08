// SPDX-License-Identifier: MPL-2.0
//! MoveBoardOverlay: the overlay put somewhere of its own.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;

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
/// - Waits: for the pointer's lock while another task moves the pointer,
///   and on a board that sends rows over a bus, for that. From a task,
///   never from an input handler.
/// - Interrupts: no.
/// - Locks: takes rtg's pointer lock, a semaphore; no spinlock may be held.
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
    const sys = rb.sys_base;
    sys.ObtainSemaphore(&rb.pointer_lock);
    defer sys.ReleaseSemaphore(&rb.pointer_lock);
    const was_following = board.overlay_follows != 0;
    board.overlay_follows = 0;
    if (!was_following and board.overlay_x == x and board.overlay_y == y) return;
    board.overlay_x = x;
    board.overlay_y = y;
    const image = board.overlay orelse return;
    const ops = board.ops orelse return;
    const move_overlay = ops.move_overlay orelse return;
    move_overlay(board, x - @as(i32, @intCast(image.hot_x)), y - @as(i32, @intCast(image.hot_y)));
}
