// SPDX-License-Identifier: MPL-2.0
//! WindowToFront: brings a window to the front.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const depthChanged = _window.depthChanged;
const lock = _window.lock;
const repairScreen = _window.repairScreen;
const unlock = _window.unlock;

/// Brings a window to the front.
///
/// SYNOPSIS:
/// ```zig
/// fn WindowToFront(ib: *IntuitionBase, window: *Window) void
/// ```
///
/// SINCE: 0.5. LVO -156.
///
/// INPUTS:
/// - `window` - the window.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// In front of every other window of its kind on the screen: a backdrop
/// window stays behind the ordinary ones. What it uncovers of itself is
/// repaired if it is a simple-refresh window.
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
/// `WindowToBack`
///
/// EXAMPLES:
/// ```zig
/// ib.WindowToFront(window);
/// ```
pub fn WindowToFront(ib: *IntuitionBase, window: *Window) void {
    lock(ib);
    defer unlock(ib);
    _ = ib.layers_base.UpfrontLayer(window.layer);
    // The interior belongs immediately in front of its border, wherever the
    // border has gone.
    if (window.inner_layer) |inner| _ = ib.layers_base.MoveLayerInFrontOf(inner, window.layer);
    @import("../requester/_requester.zig").follow(ib, window);
    repairScreen(ib, window.screen);
    depthChanged(ib, window);
}
