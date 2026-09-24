// SPDX-License-Identifier: MPL-2.0
//! InvertRect: Complement every pixel of a rectangle.

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

/// Complements every pixel of a rectangle with the board's engine.
///
/// SYNOPSIS:
/// ```zig
/// fn InvertRect(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect) i32
/// ```
///
/// SINCE: 1.0. LVO -132.
///
/// INPUTS:
/// - `dest` - the buffer, of a board.
/// - `area` - the rectangle.
///
/// RESULT:
/// As for `FillRect`.
///
/// BEHAVIOR:
/// As for `FillRect`: cut to the buffer here, and the engine's or nobody's.
///
/// CONTEXT:
/// - Waits: only if the driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Forbid: must not be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FillRect`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.InvertRect(buffer, &area);
/// ```
pub fn InvertRect(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect) i32 {
    if (!drawable(dest)) return err.RTGERR_BAD_ARG;
    const board = boardOf(dest) orelse return err.RTGERR_BAD_ARG;
    const cut = clip(dest, area) orelse return err.RTGERR_OK;
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const invert = ops.invert_rect orelse return err.RTGERR_NOT_SUPPORTED;
    return invert(board, dest, &cut);
}
