// SPDX-License-Identifier: MPL-2.0
//! CloseWindow: closes a window.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _gadget = @import("../gadget/_gadget.zig");
const _screen = @import("../screen/_screen.zig");
const _window = @import("_window.zig");
const Window = _window.Window;
const disposeParts = _window.disposeParts;
const dropPort = _window.dropPort;
const lock = _window.lock;
const reclaim = _window.reclaim;
const repairScreen = _window.repairScreen;
const unlock = _window.unlock;

/// Closes a window.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseWindow(ib: *IntuitionBase, window: ?*Window) void
/// ```
///
/// SINCE: 0.5. LVO -136.
///
/// INPUTS:
/// - `window` - the window, or null, which does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Its layer goes, so what it covered is uncovered and any simple-refresh
/// window underneath is repaired. Messages still waiting on its port are
/// freed with the port. If it was active, no window is. A window opened on
/// a public screen by name, or on the default one, ends its visit, which
/// may be the last the screen's owner is waiting for.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and the layers' locks.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The window, its RastPort and its port are gone. Every message the
/// program took off the port must have been replied first.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenWindowTagList`
///
/// EXAMPLES:
/// ```zig
/// ib.CloseWindow(window);
/// ```
pub fn CloseWindow(ib: *IntuitionBase, window: ?*Window) void {
    const w = window orelse return;
    const s = w.screen;
    lock(ib);
    defer unlock(ib);
    if (ib.active_window == w) {
        ib.active_window = null;
        // No window active: the screen says its own title again.
        if (s.title != s.default_title) {
            s.title = s.default_title;
            _screen.drawBar(ib, s);
        }
    }
    @import("../requester/_requester.zig").takeAll(ib, w);
    @import("../input/_input.zig").forget(ib, w);
    _gadget.detach(ib, w);
    ib.sys_base.Remove(@ptrCast(&w.node));
    dropPort(ib, w);
    reclaim(ib, w);
    // The gadgets' RastPort goes before the layer whose pixels it names.
    if (w.gi_rp) |gi_rp| ib.graphics_base.FreeRastPort(gi_rp);
    w.gi_rp = null;
    if (w.inner_layer) |inner| ib.layers_base.DeleteLayer(inner);
    w.inner_layer = null;
    w.inner_rp = null;
    ib.layers_base.DeleteLayer(w.layer);
    disposeParts(ib, w);
    const visitor = w.more_flags & _window.WMF_VISITOR != 0;
    ib.sys_base.FreeMem(w, @sizeOf(Window));
    repairScreen(ib, s);
    if (visitor) _screen.leave(ib, s);
}
