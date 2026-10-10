// SPDX-License-Identifier: MPL-2.0
//! BlendRect: Lay a colour over a rectangle by its alpha.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _engine = @import("_engine.zig");
const clip = _engine.clip;
const boardOf = _engine.boardOf;
const drawable = _engine.drawable;
const err = rtg.errors;

/// Lays a colour over a rectangle of a buffer with the board's engine,
/// by the colour's alpha.
///
/// SYNOPSIS:
/// ```zig
/// fn BlendRect(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) i32
/// ```
///
/// SINCE: 1.4. LVO -248.
///
/// INPUTS:
/// - `dest` - the buffer, of a board.
/// - `area` - the rectangle.
/// - `color` - 0xAARRGGBB: the colour and how much of it covers.
///
/// RESULT:
/// As for `FillRect`.
///
/// BEHAVIOR:
/// Every pixel of the rectangle is mixed with the colour by its alpha:
/// 255 is the colour, 0 leaves the pixel as it was. The rectangle is cut
/// to the buffer here. A translucent plate over a selection, a shade over
/// what cannot be chosen.
///
/// CONTEXT:
/// - Waits: only if the driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: no spinlock may be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FillRect`, `BlendPixels`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.BlendRect(buffer, &.{ .x = 0, .y = 0, .width = 200, .height = 40 }, 0x8000_40C0);
/// ```
pub fn BlendRect(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) i32 {
    if (!drawable(dest)) return err.RTGERR_BAD_ARG;
    const board = boardOf(dest) orelse return err.RTGERR_BAD_ARG;
    const cut = clip(dest, area) orelse return err.RTGERR_OK;
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const blend = ops.blend_rect orelse return err.RTGERR_NOT_SUPPORTED;
    return blend(board, dest, &cut, color);
}
