// SPDX-License-Identifier: MPL-2.0
//! RefreshRect: A rectangle of a buffer was written: hand its pixels to
//! the display.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _engine = @import("../engine/_engine.zig");
const boardOf = _engine.boardOf;
const clip = _engine.clip;
const drawable = _engine.drawable;
const err = rtg.errors;

/// Hands a rectangle of a buffer that was written on to the display.
///
/// SYNOPSIS:
/// ```zig
/// fn RefreshRect(rb: *RtgBase, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect) i32
/// ```
///
/// SINCE: 1.5. LVO -256.
///
/// INPUTS:
/// - `bitmap` - the buffer.
/// - `area` - the rectangle written.
///
/// RESULT:
/// `RTGERR_OK` - also for a rectangle with nothing of it inside the
/// buffer - `RTGERR_BAD_ARG` for a buffer with no pixels or no board,
/// `RTGERR_NOT_SUPPORTED` for a board that needs no telling, or what the
/// driver answered.
///
/// BEHAVIOR:
/// What `RefreshBitMap` does for rows, for a rectangle: what a caller
/// that wrote part of a row - a window, a tile of a picture drawn in
/// tiles - calls when it has finished. A board whose display reads the
/// buffer through a cache the CPU writes into writes back only the
/// rectangle's pixels, where whole rows would write back the rest of
/// each row too. A board that has no way of its own is handed the
/// rectangle's rows, as `RefreshBitMap` would hand them. The rectangle is
/// cut to the buffer first.
///
/// Rectangles that do not overlap may be handed on at once by several
/// tasks, as tiles drawn on several cores are.
///
/// A buffer with a `watch` hook is not the board's to hear about: the
/// hook is called instead, with the buffer and the rectangle cut to it,
/// in the task that handed it on, and this answers `RTGERR_OK`. That is
/// how a window's own buffer on a composed screen tells whoever copies it
/// on to the screen.
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
/// `RefreshBitMap`, `AllocBitMap`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.RefreshRect(buffer, &.{ .x = 64, .y = 128, .width = 64, .height = 64 });
/// ```
pub fn RefreshRect(rb: *RtgBase, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect) i32 {
    if (!drawable(bitmap)) return err.RTGERR_BAD_ARG;
    const cut = clip(bitmap, area) orelse return err.RTGERR_OK;
    if (bitmap.watch) |hook| {
        _ = rb.utility_base.CallHookPkt(hook, bitmap, @constCast(&cut));
        return err.RTGERR_OK;
    }
    const board = boardOf(bitmap) orelse return err.RTGERR_BAD_ARG;
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    if (ops.refresh_rect) |refresh_rect| return refresh_rect(board, bitmap, &cut);
    const refresh = ops.refresh orelse return err.RTGERR_NOT_SUPPORTED;
    return refresh(board, bitmap, @intCast(cut.y), @intCast(cut.height));
}
