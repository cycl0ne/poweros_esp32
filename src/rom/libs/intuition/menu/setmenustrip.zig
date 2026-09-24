// SPDX-License-Identifier: MPL-2.0
//! SetMenuStrip: gives a window its menus.

const sdk = @import("sdk");
const Menu = sdk.intuition.Menu;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const _menu = @import("_menu.zig");
const menus = @import("../input/menus.zig");

/// Gives a window its menus.
///
/// SYNOPSIS:
/// ```zig
/// fn SetMenuStrip(ib: *IntuitionBase, window: *Window, menu_strip: *Menu) bool
/// ```
///
/// SINCE: 0.12. LVO -264.
///
/// INPUTS:
/// - `window` - the window.
/// - `menu_strip` - the first `Menu` of the strip, the others linked through
///   `next_menu`, each with its items.
///
/// RESULT:
/// Always true.
///
/// BEHAVIOR:
/// Each menu's panel is laid out from its items - the smallest rectangle
/// that holds every item's box and what its text or image, its checkmark
/// and its shortcut take up, with a trim, and at least as wide as the
/// title - into the menu's `jazz_x`..`beat_y`, and the strip becomes the
/// window's. From then on the menu button over the window, while it is
/// active and does not trap the button, shows it, and a right-Amiga key
/// with an item's `command` picks that item.
///
/// A strip the window already had is simply replaced. When the window's
/// menus are being shown, that session ends first and the window is sent
/// IDCMP_MENUPICK `MENUNULL`.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The strip stays the caller's, and must stay where it is, unchanged but
/// for its checkmarks and enabling, until `ClearMenuStrip` takes it off
/// again - which must happen before the window closes.
///
/// NOTES:
/// It is the call to make in reply to IDCMP_MENUVERIFY `MENUHOT`, when a
/// program wants to change its menus just before they are shown: the
/// session waiting for the reply shows the new strip.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ClearMenuStrip`, `ResetMenuStrip`, `ItemAddress`, `sdk.intuition.menus`
///
/// EXAMPLES:
/// ```zig
/// _ = ib.SetMenuStrip(window, &project_menu);
/// defer ib.ClearMenuStrip(window);
/// ```
pub fn SetMenuStrip(ib: *IntuitionBase, window: *Window, menu_strip: *Menu) bool {
    _window.lock(ib);
    defer _window.unlock(ib);
    menus.endFor(ib, window);
    _menu.layOut(ib, window, menu_strip);
    window.menu_strip = menu_strip;
    return true;
}
