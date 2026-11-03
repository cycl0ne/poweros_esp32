// SPDX-License-Identifier: MPL-2.0
//! HideControl: a window takes in the hidden windows of its screen.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _hide = @import("_hide.zig");
const _window = @import("_window.zig");
const Window = _window.Window;

/// A window takes in the hidden windows of its screen, or gives that up.
///
/// SYNOPSIS:
/// ```zig
/// fn HideControl(ib: *IntuitionBase, window: *Window, on: bool) bool
/// ```
///
/// SINCE: 0.83. LVO -556.
///
/// INPUTS:
/// - `window` - the window that takes them in: the dock's own window,
///   where there is a dock.
/// - `on` - true to take them in, false to give that up again.
///
/// RESULT:
/// True when the screen stands as asked. False only for `on` with another
/// window of the screen already taking them in: there is one host to a
/// screen, so a second dock does not quietly take the first one's place.
///
/// BEHAVIOR:
/// While a screen has such a window, every other window of it that can
/// have one is given a hide gadget - the fourth gadget in the title bar,
/// left of the zoom and depth gadgets - and pressing that gadget puts the
/// window away (`HideWindow`). A window whose title bar has no room for
/// one more gadget, one opened with `WA_HideGadget` false - a system
/// requester says that of itself - and the on-screen keyboard are left
/// without; so is the host itself, since a window that took the way back
/// with it would be a window gone. Windows opening later are given the
/// gadget as they open.
///
/// The host is the way back, so it is also the end of it: giving this up,
/// closing the window, or the task ending with it brings every hidden
/// window of the screen back where it stood and takes the gadgets off
/// again. A program that puts windows away without being a host - calling
/// `HideWindow` itself - is on its own for the way back, as it always was.
///
/// Nothing here hides a window or shows one: it says who answers for the
/// ones that are hidden.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and the layers' locks while
///   the borders are drawn.
/// - Interrupts: no. It may wait, and it allocates the gadgets' images.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands. The gadgets are intuition's, made and freed
/// with the hosting.
///
/// NOTES:
/// A screen of a program's own has no host unless the program makes one
/// of its windows into one. That is on purpose: the gadget is there only
/// where something shows the way back.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `HideWindow`, `ShowWindow`, `NextWindow`, `GetWindowAttrs`
/// (`WA_Hidden`), `OpenWindowTagList` (`WA_HideGadget`)
///
/// EXAMPLES:
/// ```zig
/// // The dock's window takes the hidden windows of the desktop screen.
/// if (!ib.HideControl(dock_window, true)) {
///     // Another dock is already showing them.
/// }
/// ```
pub fn HideControl(ib: *IntuitionBase, window: *Window, on: bool) bool {
    _window.lock(ib);
    defer _window.unlock(ib);
    return _hide.control(ib, window, on);
}
