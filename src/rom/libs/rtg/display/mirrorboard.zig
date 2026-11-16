// SPDX-License-Identifier: MPL-2.0
//! MirrorBoard: Mirror the picture about each axis.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const composer = @import("../compose/_compose.zig");

/// Mirrors a board's picture about each axis, or shows it unturned.
///
/// SYNOPSIS:
/// ```zig
/// fn MirrorBoard(rb: *RtgBase, board: *rtg.RtgBoard, mirror_x: bool, mirror_y: bool) i32
/// ```
///
/// SINCE: 1.0. LVO -208.
///
/// INPUTS:
/// - `board` - the board.
/// - `mirror_x` - whether the picture is mirrored left to right.
/// - `mirror_y` - whether it is mirrored top to bottom.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_NOT_SUPPORTED` for an axis the board cannot
/// mirror (`RTGBC_MIRROR_X`, `RTGBC_MIRROR_Y`) - nothing changes then -
/// or what the driver answered, and the picture turned as it was.
///
/// BEHAVIOR:
/// Each axis is set on its own: false leaves it unturned. The picture,
/// the overlay and the pointer are mirrored alike on the way to the
/// glass, so nothing above the board changes: whoever draws and whoever
/// moves the pointer works in the picture's own coordinates. What is
/// shown is on the glass mirrored when this returns.
///
/// A board whose own hardware turns an axis - a controller's scan
/// direction, planes read backwards, a stream's lines sent last first -
/// does that axis itself. On a board whose picture the library composes
/// it mirrors every other axis as it composes; such a picture is not
/// read by the display itself for as long as it is mirrored.
///
/// `GetBoardInfo` says how the picture is turned (`mirror_x`,
/// `mirror_y`): what a touch panel's driver reads, so that a finger
/// lands on the picture. The tasks that asked are told of a change
/// (`AddRtgNotify`). A quarter turn is not this: it is a mode with its
/// sides exchanged (`RTGMF_TURNED`).
///
/// CONTEXT:
/// - Waits: for the picture delivered again, where the driver waits,
///   and while another task holds the board's lock.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: takes the board's lock, and inside it the board's compose
///   lock. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetBoardInfo`, `ComposeLines`, `MoveBoardPointer`
///
/// EXAMPLES:
/// ```zig
/// // Left and right exchanged, top and bottom as they are.
/// _ = rb.MirrorBoard(board, true, false);
/// ```
pub fn MirrorBoard(rb: *RtgBase, board: *rtg.RtgBoard, mirror_x: bool, mirror_y: bool) i32 {
    return composer.mirror(rb, board, mirror_x, mirror_y);
}
