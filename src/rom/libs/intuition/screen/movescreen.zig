// SPDX-License-Identifier: MPL-2.0
//! MoveScreen: a screen moved down its display, or back up.

const sdk = @import("sdk");
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;

/// Moves a screen up or down its display by an amount.
///
/// SYNOPSIS:
/// ```zig
/// fn MoveScreen(ib: *IntuitionBase, screen: *Screen, dx: i32, dy: i32) void
/// ```
///
/// SINCE: 0.29. LVO -500.
///
/// INPUTS:
/// - `screen` - the screen.
/// - `dx` - across: screens are as wide as their display, so it stays
///   where it is.
/// - `dy` - down, in lines; up for less than 0.
///
/// RESULT:
/// Nothing. GetScreenAttrs' `SA_Top` says where it went.
///
/// BEHAVIOR:
/// The screen goes as far as it may: not above its display's top, and not
/// so far down that its bar leaves the glass, so it can be pulled back. The
/// screen behind shows above it, from its own top - and above that, the one
/// behind it - and the display's home where no screen reaches. Nothing is
/// drawn again: each screen keeps its picture, and the display shows the
/// new bands at its next frame. A screen opened with `{SA_Draggable,
/// false}` does not move, nor does an exclusive one.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and for the display to take
///   the new picture up at its next frame.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// What the pointer is over goes with the bands: a press above a screen
/// pulled down is a press on the screen behind it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ScreenPositionTagList`, `ScreenDepth`, `GetScreenAttrs`
///
/// EXAMPLES:
/// ```zig
/// ib.MoveScreen(screen, 0, 200); // pulled down 200 lines
/// ib.MoveScreen(screen, 0, -200); // and back
/// ```
pub fn MoveScreen(ib: *IntuitionBase, screen: *Screen, dx: i32, dy: i32) void {
    _ = dx;
    _screen.lock(ib);
    defer _screen.unlock(ib);
    if (!screen.draggable) return;
    _screen.moveTo(ib, screen, screen.top +| dy);
}
