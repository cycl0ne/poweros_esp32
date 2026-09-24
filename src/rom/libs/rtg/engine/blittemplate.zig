// SPDX-License-Identifier: MPL-2.0
//! BlitTemplate: A one-bit shape in two colours.

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

/// Draws a one-bit shape in two colours with the board's engine.
///
/// SYNOPSIS:
/// ```zig
/// fn BlitTemplate(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, shape: *const rtg.RtgTemplate) i32
/// ```
///
/// SINCE: 1.0. LVO -140.
///
/// INPUTS:
/// - `dest` - the buffer, of a board.
/// - `area` - where it lands.
/// - `shape` - the bits, their pitch and start, the two colours and what a
///   clear bit means.
///
/// RESULT:
/// As for `FillRect`, and `RTGERR_BAD_ARG` for a shape with no bits.
///
/// BEHAVIOR:
/// As for `FillRect`.
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
/// `BlitPattern`, `FillRect`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.BlitTemplate(buffer, &area, &shape);
/// ```
pub fn BlitTemplate(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, shape: *const rtg.RtgTemplate) i32 {
    if (!drawable(dest)) return err.RTGERR_BAD_ARG;
    if (shape.bits == null) return err.RTGERR_BAD_ARG;
    const board = boardOf(dest) orelse return err.RTGERR_BAD_ARG;
    const cut = clip(dest, area) orelse return err.RTGERR_OK;
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const blit = ops.blit_template orelse return err.RTGERR_NOT_SUPPORTED;
    return blit(board, dest, &cut, shape);
}
