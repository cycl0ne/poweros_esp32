// SPDX-License-Identifier: MPL-2.0
//! ShowWindow: brings a window put away back on to its screen.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const depthChanged = _window.depthChanged;
const lock = _window.lock;
const repairScreen = _window.repairScreen;
const unlock = _window.unlock;

/// Brings a window put away back on to its screen.
///
/// SYNOPSIS:
/// ```zig
/// fn ShowWindow(ib: *IntuitionBase, window: *Window) void
/// ```
///
/// SINCE: 0.82. LVO -552.
///
/// INPUTS:
/// - `window` - the window. One that is not away is left as it is.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The window is where it was, in the depth order it was in, with its
/// interior and its requesters, and the input reaches it again. A
/// smart-refresh window has its pixels back; a simple-refresh one is owed
/// them and gets an `IDCMP_REFRESHWINDOW` as it would after being
/// uncovered, its border and its gadgets drawn again by intuition. A
/// window that asked to hear about its depth (`WA_NotifyDepth`) is told.
///
/// It is not brought to the front and it is not made active: a program
/// that wants both calls `WindowToFront` and `ActivateWindow` after this,
/// which is what the dock does when a window's cell is clicked.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and the layers' locks.
/// - Interrupts: no.
/// - Locks: none needed.
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
/// `HideWindow`, `WindowToFront`, `ActivateWindow`
///
/// EXAMPLES:
/// ```zig
/// ib.ShowWindow(window);
/// ib.WindowToFront(window);
/// ib.ActivateWindow(window);
/// ```
pub fn ShowWindow(ib: *IntuitionBase, window: *Window) void {
    const w = window;
    lock(ib);
    defer unlock(ib);
    if (w.more_flags & _window.WMF_HIDDEN == 0) return;
    w.more_flags &= ~_window.WMF_HIDDEN;
    _window.hideLayers(ib, w, false);
    // Its own damage among the rest: its border and its gadgets drawn
    // again, and its program told what it owes.
    repairScreen(ib, w.screen);
    depthChanged(ib, w);
}
