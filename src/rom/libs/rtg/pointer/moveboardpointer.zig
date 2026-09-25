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
/// not its corner. Nothing is done for the same place twice.
///
/// A board that turns its picture itself (`MirrorBoard`, `SwapBoardAxes`,
/// `SetBoardGap`) turns the pointer with it: the driver lays the pointer
/// into the picture's own order on its way out, before the turn.
///
/// CONTEXT:
/// - Waits: no. Made for an input handler, on every pointer event.
/// - Interrupts: no. A driver may send the rows the pointer left over a
///   bus.
/// - Forbid: taken for the moment it takes the driver to move it.
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
    sys.Forbid();
    defer sys.Permit();
    if (board.pointer_x == x and board.pointer_y == y) return;
    board.pointer_x = x;
    board.pointer_y = y;
    const image = board.pointer orelse return;
    const ops = board.ops orelse return;
    const move_pointer = ops.move_pointer orelse return;
    move_pointer(board, x - @as(i32, @intCast(image.hot_x)), y - @as(i32, @intCast(image.hot_y)));
}
