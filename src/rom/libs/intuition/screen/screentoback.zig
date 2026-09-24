// SPDX-License-Identifier: MPL-2.0
//! ScreenToBack: puts a screen behind the others on its display.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;

/// Puts a screen behind the others on its display.
///
/// SYNOPSIS:
/// ```zig
/// fn ScreenToBack(_: *IntuitionBase, screen: *Screen) void
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
/// As `ScreenToFront`: with one screen to a display there is no other to
/// put in front of it.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no. - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ScreenToFront`
///
/// EXAMPLES:
/// ```zig
/// ib.ScreenToBack(screen);
/// ```
pub fn ScreenToBack(_: *IntuitionBase, screen: *Screen) void {
    _ = screen;
}
