// SPDX-License-Identifier: MPL-2.0
//! ScreenToFront: brings a screen to the front of its display.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;
const lock = _screen.lock;
const restack = _screen.restack;
const unlock = _screen.unlock;

/// Brings a screen to the front of its display.
///
/// SYNOPSIS:
/// ```zig
/// fn ScreenToFront(ib: *IntuitionBase, screen: *Screen) void
/// ```
///
/// SINCE: 0.4. LVO -108.
///
/// INPUTS:
/// - `screen` - the screen.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// It goes in front of every other screen of its display, and the display
/// shows it from the start of the next frame: its buffer is shown in place
/// of the one that was, whole, and nothing is copied. Its windows keep
/// whatever they had; the active window stays the one it was.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and for the display to take
///   the new picture up at the next frame.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// The pointer and the menu button reach the screen in front.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ScreenToBack`, `ScreenDepth`, `OpenScreenTagList` (`SA_Behind`)
///
/// EXAMPLES:
/// ```zig
/// ib.ScreenToFront(screen);
/// ```
pub fn ScreenToFront(ib: *IntuitionBase, screen: *Screen) void {
    lock(ib);
    defer unlock(ib);
    restack(ib, screen, true);
}
