// SPDX-License-Identifier: MPL-2.0
//! ScreenDepth: a screen to the front of its display or to the back.

const sdk = @import("sdk");
const sc = sdk.intuition.screens;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;
const lock = _screen.lock;
const restack = _screen.restack;
const unlock = _screen.unlock;

/// Moves a screen to the front of its display or to the back.
///
/// SYNOPSIS:
/// ```zig
/// fn ScreenDepth(ib: *IntuitionBase, screen: *Screen, flags: u32) void
/// ```
///
/// SINCE: 0.14. LVO -388.
///
/// INPUTS:
/// - `screen` - the screen.
/// - `flags` - `SDEPTH_TOFRONT` or `SDEPTH_TOBACK`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// `ScreenToFront` or `ScreenToBack`, chosen by a value - for a gadget or
/// a key that flips between the two.
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
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ScreenToFront`, `ScreenToBack`
///
/// EXAMPLES:
/// ```zig
/// ib.ScreenDepth(screen, sc.SDEPTH_TOBACK);
/// ```
pub fn ScreenDepth(ib: *IntuitionBase, screen: *Screen, flags: u32) void {
    lock(ib);
    defer unlock(ib);
    restack(ib, screen, flags & sc.SDEPTH_TOBACK == 0);
}
