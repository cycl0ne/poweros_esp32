// SPDX-License-Identifier: MPL-2.0
//! EndRefresh: ends a redraw begun with BeginRefresh.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const WF_IN_REFRESH = _window.WF_IN_REFRESH;
const Window = _window.Window;
const innerLayer = _window.innerLayer;
const lock = _window.lock;
const unlock = _window.unlock;

/// Ends a redraw begun with BeginRefresh.
///
/// SYNOPSIS:
/// ```zig
/// fn EndRefresh(ib: *IntuitionBase, window: *Window, complete: bool) void
/// ```
///
/// SINCE: 0.5. LVO -176.
///
/// INPUTS:
/// - `window` - the window.
/// - `complete` - true when everything is drawn again; false keeps what
///   needed drawing for another BeginRefresh.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Drawing reaches the whole window again, the window's layer that
/// `BeginRefresh` held is let go, and what was drawn goes to the display.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and the layers' locks.
/// - Interrupts: no.
/// - Locks: the window's layer, from `BeginRefresh`; it is let go of
///   before the screen list's semaphore is taken, which a window move
///   takes before a layer's.
/// - Process: a Task will do: the one that called `BeginRefresh`.
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
/// `BeginRefresh`
///
/// EXAMPLES:
/// ```zig
/// ib.EndRefresh(window, true);
/// ```
pub fn EndRefresh(ib: *IntuitionBase, window: *Window, complete: bool) void {
    // The flag is this task's own, set by its BeginRefresh. The layer goes
    // first: a window move holds the screen list's semaphore while it
    // waits for the layers, so taking that semaphore with the layer still
    // held could wait for ever.
    if (window.flags & WF_IN_REFRESH == 0) return;
    ib.layers_base.EndUpdate(innerLayer(window), complete);
    lock(ib);
    defer unlock(ib);
    window.flags &= ~WF_IN_REFRESH;
}
