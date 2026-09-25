// SPDX-License-Identifier: MPL-2.0
//! MoveWindowInFrontOf: puts a window just in front of another.

const layers = @import("sdk").layers;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const WF_BACKDROP = _window.WF_BACKDROP;
const depthChanged = _window.depthChanged;
const lock = _window.lock;
const repairScreen = _window.repairScreen;
const unlock = _window.unlock;

/// Puts a window just in front of another.
///
/// SYNOPSIS:
/// ```zig
/// fn MoveWindowInFrontOf(ib: *IntuitionBase, window: *Window, behind: *Window) void
/// ```
///
/// SINCE: 0.14. LVO -344.
///
/// INPUTS:
/// - `window` - the window to move.
/// - `behind` - the window it goes in front of.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The window goes in front of `behind` and of everything that belongs to
/// it - its interior and its requesters - and behind whatever was in front
/// of those. What that uncovers of other windows is repaired.
///
/// Nothing happens when the two are on different screens, are the same
/// window, or are of different kinds: a backdrop window stays behind every
/// other window, and an ordinary one in front of every backdrop window.
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
/// A window asking for IDCMP_CHANGEWINDOW with `WA_NotifyDepth` is told
/// its depth changed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WindowToFront`, `WindowToBack`
///
/// EXAMPLES:
/// ```zig
/// // The palette window stays just in front of the picture it belongs to.
/// ib.MoveWindowInFrontOf(palette, picture);
/// ```
pub fn MoveWindowInFrontOf(ib: *IntuitionBase, window: *Window, behind: *Window) void {
    if (window == behind or window.screen != behind.screen) return;
    if ((window.flags & WF_BACKDROP) != (behind.flags & WF_BACKDROP)) return;
    lock(ib);
    defer unlock(ib);
    const lb = ib.layers_base;
    _ = lb.MoveLayerInFrontOf(window.layer, frontmost(behind));
    if (window.inner_layer) |inner| _ = lb.MoveLayerInFrontOf(inner, window.layer);
    @import("../requester/_requester.zig").follow(ib, window);
    repairScreen(ib, window.screen);
    depthChanged(ib, window);
}

/// The layer furthest in front of those that belong to a window: its
/// newest requester's, its interior, or its own.
fn frontmost(w: *Window) *layers.Layer {
    var req = w.first_request;
    while (req) |r| : (req = r.older) {
        if (r.layer) |layer| return layer;
    }
    return w.inner_layer orelse w.layer;
}
