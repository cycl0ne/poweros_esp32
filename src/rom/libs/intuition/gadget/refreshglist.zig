// SPDX-License-Identifier: MPL-2.0
//! RefreshGList: draws gadgets of a window.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const Object = intuition.Object;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const _gadget = @import("_gadget.zig");
const renderRange = _gadget.renderRange;

/// Draws gadgets of a window.
///
/// SYNOPSIS:
/// ```zig
/// fn RefreshGList(ib: *IntuitionBase, gadget: *Object, window: *Window,
///     count: i32) void
/// ```
///
/// SINCE: 0.6. LVO -192.
///
/// INPUTS:
/// - `gadget` - the first to draw, in the window's list.
/// - `window` - the window.
/// - `count` - how many from it on; -1 for the rest of the list.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Each is sent `GM_RENDER` with `GREDRAW_REDRAW` and the window's
/// RastPort, its layer held.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore and the window's layer.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// A window draws its gadgets itself when it opens, when a simple window is
/// uncovered and when it is sized; this is for the program's own changes.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddGList`
///
/// EXAMPLES:
/// ```zig
/// ib.RefreshGList(first, window, -1);
/// ```
pub fn RefreshGList(ib: *IntuitionBase, gadget: *Object, window: *Window, count: i32) void {
    _window.lock(ib);
    defer _window.unlock(ib);
    renderRange(ib, window, gadget, count);
}
