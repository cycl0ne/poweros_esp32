// SPDX-License-Identifier: MPL-2.0
//! BeginRefresh: begins redrawing what a window lost.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const WF_IN_REFRESH = _window.WF_IN_REFRESH;
const WF_REFRESH_SENT = _window.WF_REFRESH_SENT;
const Window = _window.Window;
const innerLayer = _window.innerLayer;
const lock = _window.lock;
const unlock = _window.unlock;

/// Begins redrawing what a window lost.
///
/// SYNOPSIS:
/// ```zig
/// fn BeginRefresh(ib: *IntuitionBase, window: *Window) void
/// ```
///
/// SINCE: 0.5. LVO -172.
///
/// INPUTS:
/// - `window` - the window, after an `IDCMP_REFRESHWINDOW`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Until `EndRefresh`, drawing through the window's RastPort reaches only
/// the part that needs it, so a program may simply draw everything. A
/// further IDCMP_REFRESHWINDOW can be sent from here on. For a window
/// with nothing to redraw it does nothing, and so does its EndRefresh.
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
/// - The border was put back before the message was sent.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `EndRefresh`
///
/// EXAMPLES:
/// ```zig
/// ib.BeginRefresh(window);
/// drawEverything(window);
/// ib.EndRefresh(window, true);
/// ```
pub fn BeginRefresh(ib: *IntuitionBase, window: *Window) void {
    lock(ib);
    defer unlock(ib);
    window.flags &= ~WF_REFRESH_SENT;
    if (ib.layers_base.BeginUpdate(innerLayer(window))) window.flags |= WF_IN_REFRESH;
}
