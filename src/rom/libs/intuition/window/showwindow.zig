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
/// On a screen whose windows are composed it is shown unseen and fades
/// in (`IPREFS_WindowFade`), or grows back out of the box of the window
/// that took it in (`HideControl`), which is how it went there; one
/// still on its way away is turned round where it is and comes back from
/// there, so a window put away and fetched again at once never leaves
/// the display.
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
    // A window still fading away is turned round where it is and keeps
    // the layers it never lost; one that is away is shown unseen and
    // fades in, or shown as it is where nothing fades. Either way its
    // own damage is among the rest: its border and its gadgets drawn
    // again, and its program told what it owes.
    switch (@import("_fade.zig").showing(ib, w)) {
        .turned => {},
        .fades, .at_once => {
            _window.hideLayers(ib, w, false);
            repairScreen(ib, w.screen);
        },
    }
    depthChanged(ib, w);
}
