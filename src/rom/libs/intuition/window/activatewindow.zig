// SPDX-License-Identifier: MPL-2.0
//! ActivateWindow: makes a window the active one.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const activate = _window.activate;
const lock = _window.lock;
const unlock = _window.unlock;

/// Makes a window the active one.
///
/// SYNOPSIS:
/// ```zig
/// fn ActivateWindow(ib: *IntuitionBase, window: *Window) void
/// ```
///
/// SINCE: 0.5. LVO -164.
///
/// INPUTS:
/// - `window` - the window.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Its border is drawn in the fill pen and its title in the fill-text
/// pen; the window that was active has its border drawn in the background
/// pen and is told `IDCMP_INACTIVEWINDOW`, and this one `IDCMP_ACTIVEWINDOW`.
/// One window is active at a time, across every screen. Its screen's bar
/// shows the window's screen title (`WA_ScreenTitle`, or the screen's own);
/// a screen the active window leaves shows its own title again.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and the layers' locks.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// - Once there is input, the active window is the one keys go to.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenWindowTagList` (`WA_Activate`)
///
/// EXAMPLES:
/// ```zig
/// ib.ActivateWindow(window);
/// ```
pub fn ActivateWindow(ib: *IntuitionBase, window: *Window) void {
    lock(ib);
    defer unlock(ib);
    activate(ib, window);
}
