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
/// Drawing reaches the whole window again.
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
    lock(ib);
    defer unlock(ib);
    if (window.flags & WF_IN_REFRESH == 0) return;
    window.flags &= ~WF_IN_REFRESH;
    ib.layers_base.EndUpdate(innerLayer(window), complete);
}
