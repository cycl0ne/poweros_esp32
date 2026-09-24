// SPDX-License-Identifier: MPL-2.0
//! WindowToBack: puts a window at the back.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const depthChanged = _window.depthChanged;
const lock = _window.lock;
const repairScreen = _window.repairScreen;
const unlock = _window.unlock;

/// Puts a window at the back.
///
/// SYNOPSIS:
/// ```zig
/// fn WindowToBack(ib: *IntuitionBase, window: *Window) void
/// ```
///
/// SINCE: 0.5. LVO -160.
///
/// INPUTS:
/// - `window` - the window.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Behind every other window of its kind on the screen. What that
/// uncovers of the others is repaired.
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
/// `WindowToFront`
///
/// EXAMPLES:
/// ```zig
/// ib.WindowToBack(window);
/// ```
pub fn WindowToBack(ib: *IntuitionBase, window: *Window) void {
    lock(ib);
    defer unlock(ib);
    _ = ib.layers_base.BehindLayer(window.layer);
    if (window.inner_layer) |inner| _ = ib.layers_base.MoveLayerInFrontOf(inner, window.layer);
    @import("../requester/_requester.zig").follow(ib, window);
    repairScreen(ib, window.screen);
    depthChanged(ib, window);
}
