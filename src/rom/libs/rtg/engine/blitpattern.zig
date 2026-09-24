// SPDX-License-Identifier: MPL-2.0
//! BlitPattern: A one-bit tile, anchored to the buffer.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const clip = _engine.clip;
const boardOf = _engine.boardOf;
const err = rtg.errors;
const drawable = _engine.drawable;
const _engine = @import("_engine.zig");

/// Fills a rectangle with a one-bit tile with the board's engine.
///
/// SYNOPSIS:
/// ```zig
/// fn BlitPattern(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, tile: *const rtg.RtgPattern) i32
/// ```
///
/// SINCE: 1.0. LVO -144.
///
/// INPUTS:
/// - `dest` - the buffer, of a board.
/// - `area` - the rectangle.
/// - `tile` - the bits, its size, the two colours and where it is anchored.
///
/// RESULT:
/// As for `FillRect`, and `RTGERR_BAD_ARG` for a tile with no bits or no
/// size.
///
/// BEHAVIOR:
/// The tile is anchored to the buffer, so two rectangles of one pattern
/// line up where they meet.
///
/// CONTEXT:
/// - Waits: only if the driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Forbid: must not be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The bits stay the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BlitTemplate`, `FillRect`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.BlitPattern(buffer, &desktop, &tile);
/// ```
pub fn BlitPattern(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, tile: *const rtg.RtgPattern) i32 {
    if (!drawable(dest)) return err.RTGERR_BAD_ARG;
    if (tile.bits == null or tile.width == 0 or tile.height == 0) return err.RTGERR_BAD_ARG;
    const board = boardOf(dest) orelse return err.RTGERR_BAD_ARG;
    const cut = clip(dest, area) orelse return err.RTGERR_OK;
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const blit = ops.blit_pattern orelse return err.RTGERR_NOT_SUPPORTED;
    return blit(board, dest, &cut, tile);
}
