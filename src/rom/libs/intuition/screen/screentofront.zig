// SPDX-License-Identifier: MPL-2.0
//! ScreenToFront: brings a screen to the front of its display.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;

/// Brings a screen to the front of its display.
///
/// SYNOPSIS:
/// ```zig
/// fn ScreenToFront(_: *IntuitionBase, screen: *Screen) void
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
/// A display shows one screen, so it is always at the front and this
/// changes nothing. The slot is here so that a program written now keeps
/// working when a display can hold several.
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
/// `ScreenToBack`
///
/// EXAMPLES:
/// ```zig
/// ib.ScreenToFront(screen);
/// ```
pub fn ScreenToFront(_: *IntuitionBase, screen: *Screen) void {
    _ = screen;
}
