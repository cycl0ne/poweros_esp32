// SPDX-License-Identifier: MPL-2.0
//! HideWindow: puts a window away without closing it.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const _screen = @import("../screen/_screen.zig");
const depthChanged = _window.depthChanged;
const lock = _window.lock;
const repairScreen = _window.repairScreen;
const unlock = _window.unlock;

/// Puts a window away without closing it.
///
/// SYNOPSIS:
/// ```zig
/// fn HideWindow(ib: *IntuitionBase, window: *Window) void
/// ```
///
/// SINCE: 0.82. LVO -548.
///
/// INPUTS:
/// - `window` - the window. One already away is left as it is.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Nothing of the window is on the display any more - its interior and
/// the requesters up in it with it - and nothing of the input reaches it:
/// it is not under the pointer, it cannot be clicked, and it cannot be
/// the active window. What it covered is uncovered as if it had closed,
/// and if it was the active window the activation goes where it would
/// have gone had it closed: to the window on the screen that was active
/// most recently and is not away itself.
///
/// On a screen whose windows are composed it fades out as a window
/// closing does (`IPREFS_WindowFade`) - or, where a window has taken the
/// screen's hidden windows in (`HideControl`), flies into that window's
/// box instead: a picture of its pixels, shrinking as it goes, which is
/// the way into the dock's row. Either way it is away from the moment it
/// is asked for: the activation has already gone, and nothing of the
/// input reaches it while its picture is still on its way.
///
/// Everything else about it stays. It is still open and still on its
/// screen's list in the place it had, with its number, its port, its
/// menus, its gadgets, its layer and its pixels; `NextWindow` still walks
/// over it and `WA_Hidden` says how it is, so a program showing the
/// windows of a screen - the dock's row of them - can list it and bring
/// it back with `ShowWindow`. Its program goes on running and may draw
/// into it, move it, size it and close it as before; a window that asked
/// to hear about its depth (`WA_NotifyDepth`) is told.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and the layers' locks.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands. The window stays its program's, to show again
/// or to close.
///
/// NOTES:
/// A window nobody can bring back is a window gone: it is for a program
/// that puts the way back somewhere - the dock lists it - or that shows
/// the window again itself.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ShowWindow`, `GetWindowAttrs`, `NextWindow`, `CloseWindow`
///
/// EXAMPLES:
/// ```zig
/// ib.HideWindow(window);
/// ```
pub fn HideWindow(ib: *IntuitionBase, window: *Window) void {
    const w = window;
    lock(ib);
    defer unlock(ib);
    if (w.more_flags & _window.WMF_HIDDEN != 0) return;
    const s = w.screen;
    const was_active = ib.active_window == w;
    if (was_active) {
        ib.active_window = null;
        // Drawn the way an inactive window is before it goes, so that is
        // how it comes back - a smart window's pixels are kept as they
        // are at this moment - and its program told, as it would be told
        // by another window taking the activation.
        _window.deactivate(ib, w);
        // No window active: the screen says its own title again.
        if (s.title != s.default_title) {
            s.title = s.default_title;
            _screen.drawBar(ib, s);
        }
    }
    // Nothing of it is there to be hovered, dragged, sized or pressed.
    @import("../input/_input.zig").forget(ib, w);
    @import("../input/drag.zig").forget(ib, w);
    w.more_flags |= _window.WMF_HIDDEN;
    // On a composed screen it fades out, and the fade hides its layers
    // and repairs the screen when it ends; elsewhere it goes at once.
    if (!@import("_fade.zig").hiding(ib, w)) {
        _window.hideLayers(ib, w, true);
        repairScreen(ib, s);
    }
    // Where the activation would have gone had it closed. A screen with
    // nothing left to activate keeps the default pointer.
    if (was_active) {
        if (_window.latest(s)) |next| _window.activate(ib, next) else @import("../input/pointer.zig").update(ib);
    }
    depthChanged(ib, w);
}
