// SPDX-License-Identifier: MPL-2.0
//! ChangeScreenBuffer: shows one of a screen's buffers.

const sdk = @import("sdk");
const sc = sdk.intuition.screens;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;
const lock = _screen.lock;
const showFront = _screen.showFront;
const unlock = _screen.unlock;

/// Shows one of a screen's buffers.
///
/// SYNOPSIS:
/// ```zig
/// fn ChangeScreenBuffer(ib: *IntuitionBase, screen: *Screen, buffer: *ScreenBuffer) bool
/// ```
///
/// SINCE: 0.14. LVO -400.
///
/// INPUTS:
/// - `screen` - the screen.
/// - `buffer` - one of its buffers from `AllocScreenBuffer`.
///
/// RESULT:
/// True when it is shown. False while the screen's menus are up: they are
/// drawn in the screen's own buffer, and taking it away would leave them
/// working unseen. Try again with the next frame.
///
/// BEHAVIOR:
/// The display takes the buffer up at the start of its next frame, whole,
/// and this returns when it has: the buffer shown before is no longer read
/// and the next frame can be drawn into it. A screen that is not in front
/// shows the buffer when it is brought forward.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and for the display's next
///   frame - which paces a program drawing a frame at a time to the display.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// The screen's bar, windows and menus are in its own buffer
/// (`SB_SCREEN_BITMAP`) and are seen while that one is shown.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocScreenBuffer`, `FreeScreenBuffer`
///
/// EXAMPLES:
/// ```zig
/// var buffers = [2]*sc.ScreenBuffer{ front, back };
/// var drawing: usize = 1;
/// while (running) {
///     drawFrame(buffers[drawing].rast_port);
///     if (ib.ChangeScreenBuffer(screen, buffers[drawing])) drawing ^= 1;
/// }
/// ```
pub fn ChangeScreenBuffer(ib: *IntuitionBase, screen: *Screen, buffer: *sc.ScreenBuffer) bool {
    lock(ib);
    defer unlock(ib);
    if (@import("../input/menus.zig").busy(ib)) return false;
    screen.shown = buffer.bitmap;
    showFront(ib, screen.board, screen.home);
    return true;
}
