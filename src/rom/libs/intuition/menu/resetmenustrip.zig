// SPDX-License-Identifier: MPL-2.0
//! ResetMenuStrip: gives a window back a strip it already had.

const sdk = @import("sdk");
const Menu = sdk.intuition.Menu;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const menus = @import("../input/menus.zig");

/// Gives a window back a strip it already had.
///
/// SYNOPSIS:
/// ```zig
/// fn ResetMenuStrip(ib: *IntuitionBase, window: *Window, menu_strip: *Menu) bool
/// ```
///
/// SINCE: 0.12. LVO -272.
///
/// INPUTS:
/// - `window` - the window.
/// - `menu_strip` - a strip `SetMenuStrip` has laid out, for this window or
///   another on a screen with the same font.
///
/// RESULT:
/// Always true.
///
/// BEHAVIOR:
/// As `SetMenuStrip`, without laying the panels out again: the strip keeps
/// the `jazz_x`..`beat_y` it has. It is the quick way back after
/// `ClearMenuStrip` when all that changed in the meantime is which items
/// are checked or enabled.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// As for `SetMenuStrip`: the strip stays the caller's until
/// `ClearMenuStrip`.
///
/// NOTES:
/// None.
///
/// BUGS:
/// A strip changed in any other way - an item added, a text made longer -
/// keeps panels of the old size. Use `SetMenuStrip` for that.
///
/// SEE ALSO:
/// `SetMenuStrip`, `ClearMenuStrip`
///
/// EXAMPLES:
/// ```zig
/// ib.ClearMenuStrip(window);
/// save_item.flags &= ~ITEMENABLED;
/// _ = ib.ResetMenuStrip(window, &project_menu);
/// ```
pub fn ResetMenuStrip(ib: *IntuitionBase, window: *Window, menu_strip: *Menu) bool {
    _window.lock(ib);
    defer _window.unlock(ib);
    menus.endFor(ib, window);
    window.menu_strip = menu_strip;
    return true;
}
