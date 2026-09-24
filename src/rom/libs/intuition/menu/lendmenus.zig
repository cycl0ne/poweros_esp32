// SPDX-License-Identifier: MPL-2.0
//! LendMenus: makes one window's menu button show another window's menus.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;

/// Makes one window's menu button show another window's menus.
///
/// SYNOPSIS:
/// ```zig
/// fn LendMenus(ib: *IntuitionBase, from_window: *Window, to_window: ?*Window) void
/// ```
///
/// SINCE: 0.12. LVO -288.
///
/// INPUTS:
/// - `from_window` - the window whose menu button is lent.
/// - `to_window` - the window whose menus it shows, or null for its own
///   again.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// While `from_window` is active, the menu button - and a right-Amiga
/// shortcut of `to_window`'s items - makes `to_window` active and uses its
/// menus on its screen, as though the pointer had been there. The picks go
/// to `to_window`, and `from_window` is made active again when the session
/// ends.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands. When `to_window` closes the loan ends by itself.
///
/// NOTES:
/// It is meant for a window on a small screen of controls that belongs to
/// a program whose menus are in its main window.
///
/// BUGS:
/// `to_window` really is made active for the length of the session, and
/// hears IDCMP_ACTIVEWINDOW and IDCMP_INACTIVEWINDOW about it.
///
/// SEE ALSO:
/// `SetMenuStrip`, `ActivateWindow`
///
/// EXAMPLES:
/// ```zig
/// ib.LendMenus(panel_window, main_window);
/// ```
pub fn LendMenus(ib: *IntuitionBase, from_window: *Window, to_window: ?*Window) void {
    _window.lock(ib);
    defer _window.unlock(ib);
    from_window.menu_lend = to_window;
}
