// SPDX-License-Identifier: MPL-2.0
//! OnMenu: lets a menu, an item or a subitem be picked again.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const _menu = @import("_menu.zig");
const menus = @import("../input/menus.zig");

/// Lets a menu, an item or a subitem be picked again.
///
/// SYNOPSIS:
/// ```zig
/// fn OnMenu(ib: *IntuitionBase, window: *Window, menu_number: u32) void
/// ```
///
/// SINCE: 0.12. LVO -280.
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
/// What the number names is enabled again: its ghost goes and it can be picked. A number the strip does not have, or a
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
/// `OffMenu`, `SetMenuStrip`, `sdk.intuition.menus.FULLMENUNUM`
///
/// EXAMPLES:
/// ```zig
/// ib.OnMenu(window, FULLMENUNUM(0, 2, NOSUB));
/// ```
pub fn OnMenu(ib: *IntuitionBase, window: *Window, menu_number: u32) void {
    _window.lock(ib);
    defer _window.unlock(ib);
    _menu.onOff(window.menu_strip, menu_number, true);
    menus.enablingChanged(ib, window);
}
