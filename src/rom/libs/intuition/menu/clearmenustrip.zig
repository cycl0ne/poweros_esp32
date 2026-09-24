// SPDX-License-Identifier: MPL-2.0
//! ClearMenuStrip: takes a window's menus away.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const menus = @import("../input/menus.zig");

/// Takes a window's menus away.
///
/// SYNOPSIS:
/// ```zig
/// fn ClearMenuStrip(ib: *IntuitionBase, window: *Window) void
/// ```
///
/// SINCE: 0.12. LVO -268.
///
/// INPUTS:
/// - `window` - the window.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The window has no strip afterwards: the menu button over it shows an
/// empty bar, and no shortcut picks anything. A session showing its menus
/// ends first, and the window is sent IDCMP_MENUPICK `MENUNULL`. A window
/// with no strip is left as it is.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The strip is the caller's to change or free once this returns.
///
/// NOTES:
/// Every window that was given a strip must have it cleared before it
/// closes.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetMenuStrip`, `ResetMenuStrip`
///
/// EXAMPLES:
/// ```zig
/// ib.ClearMenuStrip(window);
/// ib.CloseWindow(window);
/// ```
pub fn ClearMenuStrip(ib: *IntuitionBase, window: *Window) void {
    _window.lock(ib);
    defer _window.unlock(ib);
    menus.endFor(ib, window);
    window.menu_strip = null;
}
