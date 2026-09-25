// SPDX-License-Identifier: MPL-2.0
//! ScreenToBack: puts a screen behind the others on its display.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;
const lock = _screen.lock;
const restack = _screen.restack;
const unlock = _screen.unlock;

/// Puts a screen behind the others on its display.
///
/// SYNOPSIS:
/// ```zig
/// fn ScreenToBack(ib: *IntuitionBase, screen: *Screen) void
/// ```
///
/// SINCE: 0.4. LVO -112.
///
/// INPUTS:
/// - `screen` - the screen.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// It goes behind every other screen of its display, and the display shows
/// the one that is now in front from the start of the next frame. Nothing
/// is copied, and nothing of it is lost: it is shown as it was when it is
/// brought forward again.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and for the display to take
///   the new picture up at the next frame.
/// - Interrupts: no.
/// - Forbid: must not be held.
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
/// `ScreenToFront`, `ScreenDepth`, `OpenScreenTagList` (`SA_Behind`)
///
/// EXAMPLES:
/// ```zig
/// ib.ScreenToBack(screen);
/// ```
pub fn ScreenToBack(ib: *IntuitionBase, screen: *Screen) void {
    lock(ib);
    defer unlock(ib);
    restack(ib, screen, false);
}
