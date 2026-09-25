// SPDX-License-Identifier: MPL-2.0
//! FreeScreenBuffer: gives back a buffer from AllocScreenBuffer.

const sdk = @import("sdk");
const sc = sdk.intuition.screens;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;
const lock = _screen.lock;
const showFront = _screen.showFront;
const unlock = _screen.unlock;

/// Gives back a buffer from `AllocScreenBuffer`.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeScreenBuffer(ib: *IntuitionBase, screen: *Screen, buffer: ?*ScreenBuffer) void
/// ```
///
/// SINCE: 0.14. LVO -404.
///
/// INPUTS:
/// - `screen` - the screen it was made for.
/// - `buffer` - the buffer, or null.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A buffer being shown is replaced by the screen's own first, so the
/// screen shows its bar and windows again. A buffer made with
/// `SB_SCREEN_BITMAP` is the screen's and stays; only its record goes.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and for the display's next
///   frame when the buffer was shown.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffer and its RastPort are gone.
///
/// NOTES:
/// Every buffer of a screen is given back before the screen closes.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocScreenBuffer`, `ChangeScreenBuffer`
///
/// EXAMPLES:
/// ```zig
/// ib.FreeScreenBuffer(screen, back);
/// ```
pub fn FreeScreenBuffer(ib: *IntuitionBase, screen: *Screen, buffer: ?*sc.ScreenBuffer) void {
    const sb = buffer orelse return;
    lock(ib);
    defer unlock(ib);
    if (sb.bitmap != screen.bitmap) {
        if (screen.shown == sb.bitmap) {
            screen.shown = screen.bitmap;
            showFront(ib, screen.board, screen.home);
        }
        ib.graphics_base.FreeRastPort(sb.rast_port);
        if (ib.rtg_base) |rb| rb.FreeBitMap(sb.bitmap);
    }
    ib.sys_base.FreeMem(sb, @sizeOf(sc.ScreenBuffer));
}
