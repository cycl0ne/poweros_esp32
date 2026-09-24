// SPDX-License-Identifier: MPL-2.0
//! OffMenu: keeps a menu, an item or a subitem from being picked.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const _menu = @import("_menu.zig");
const menus = @import("../input/menus.zig");

/// Keeps a menu, an item or a subitem from being picked.
///
/// SYNOPSIS:
/// ```zig
/// fn OffMenu(ib: *IntuitionBase, window: *Window, menu_number: u32) void
/// ```
///
/// SINCE: 0.12. LVO -284.
///
/// INPUTS:
/// - `window` - the window whose strip it is.
/// - `menu_number` - which: a number naming no item is the whole menu, one
///   naming no subitem the item, and one naming a subitem that subitem.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// What the number names is disabled: shown ghosted, and it cannot be picked - a disabled title's whole panel with it. A number the strip does not have, or a
/// window with no strip, changes nothing.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// It may be called whenever the strip is the window's. While the window's
/// menus are shown, the titles and the open panels are painted again at
/// once, so what looks pickable is what can be picked.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OnMenu`, `SetMenuStrip`, `sdk.intuition.menus.FULLMENUNUM`
///
/// EXAMPLES:
/// ```zig
/// ib.OffMenu(window, FULLMENUNUM(0, 2, NOSUB));
/// ```
pub fn OffMenu(ib: *IntuitionBase, window: *Window, menu_number: u32) void {
    _window.lock(ib);
    defer _window.unlock(ib);
    _menu.onOff(window.menu_strip, menu_number, false);
    menus.enablingChanged(ib, window);
}
