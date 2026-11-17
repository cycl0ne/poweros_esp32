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
const composer = @import("../compose/_compose.zig");

/// Hands a rectangle of a buffer that was written on to the display.
///
/// SYNOPSIS:
/// ```zig
/// fn RefreshRect(rb: *RtgBase, bitmap: *rtg.RtgBitMap, area: ?*const rtg.RtgRect) i32
/// ```
///
/// SINCE: 1.5. LVO -172.
///
/// INPUTS:
/// - `bitmap` - the buffer.
/// - `area` - the rectangle written; null for the whole buffer.
///
/// RESULT:
/// `RTGERR_OK` - also for a rectangle with nothing of it inside the
/// buffer - `RTGERR_BAD_ARG` for a buffer with no pixels or no board,
/// `RTGERR_NOT_SUPPORTED` for a board that needs no telling, or what the
/// driver answered.
///
/// BEHAVIOR:
/// What a caller that wrote the pixels itself calls when it has
/// finished: a window, a tile of a picture drawn in tiles, a whole
/// buffer. The rectangle is cut to the buffer first.
///
/// Where the display reads the buffer itself, its driver is told
/// (`refresh`), for a buffer shown or not: one whose display reads
/// through a cache the CPU writes into writes back the rectangle's
/// pixels, so a buffer drawn ahead is whole when it is shown. Where the
/// display shows a picture the library composes, the rectangle is also
/// turned into the display's own - the lines of each band that shows
/// the buffer, a repeating band's all for its first row, a scaled
/// band's scaled as the band is - and the driver delivers those
/// (`update`), with the overlay and the pointer over them. A buffer no
/// band shows reaches the glass when it is shown.
///
/// On a board whose display reads the buffers itself, rectangles that do
/// not overlap may be handed on at once by several tasks, as tiles drawn
/// on several cores are; on one with a picture of its own they follow
/// each other.
///
/// A buffer with a `watch` hook is not the board's to hear about: the
/// hook is called instead, with the buffer and the rectangle cut to it,
/// in the task that handed it on, and this answers `RTGERR_OK`. That is
/// how a window's own buffer on a composed screen tells whoever copies it
/// on to the screen.
///
/// CONTEXT:
/// - Waits: for the board's compose lock on a board with a picture of
///   its own, while another task hands on, moves the pointer or shows;
///   and where the driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: takes the board's compose lock on a board with a picture of
///   its own, and never the board's lock. No spinlock may be held: a
///   driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocBitMap`, `ShowBoard`, `ComposeLines`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.RefreshRect(buffer, &.{ .x = 64, .y = 128, .width = 64, .height = 64 });
/// // All of it.
/// _ = rb.RefreshRect(buffer, null);
/// ```
pub fn RefreshRect(rb: *RtgBase, bitmap: *rtg.RtgBitMap, area: ?*const rtg.RtgRect) i32 {
    if (!drawable(bitmap)) return err.RTGERR_BAD_ARG;
    const whole = rtg.RtgRect{ .width = @intCast(bitmap.width), .height = @intCast(bitmap.height) };
    const cut = clip(bitmap, area orelse &whole) orelse return err.RTGERR_OK;
    if (bitmap.watch) |hook| {
        _ = rb.utility_base.CallHookPkt(hook, bitmap, @constCast(&cut));
        return err.RTGERR_OK;
    }
    const board = boardOf(bitmap) orelse return err.RTGERR_BAD_ARG;
    return composer.handOn(rb, board, bitmap, &cut);
}
