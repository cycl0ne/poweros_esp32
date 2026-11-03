// SPDX-License-Identifier: MPL-2.0
//! CloseWindow: closes a window.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _gadget = @import("../gadget/_gadget.zig");
const _screen = @import("../screen/_screen.zig");
const _window = @import("_window.zig");
const Window = _window.Window;
const Screen = _screen.Screen;
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
/// freed with the port; on a port the program shares between its windows
/// (`WA_UserPort`), this window's are taken off and the port is left. If
/// it was active, the window on its screen that was active most recently
/// before it is active again - a program's window when its requester
/// closes, the desktop when a program it started ends - and with none on
/// that screen, no window is. A window opened on
/// a public screen by name, or on the default one, ends its visit, which
/// may be the last the screen's owner is waiting for.
///
/// A window that took in the hidden windows of its screen
/// (`HideControl`) is the way back for them, so closing it brings every
/// one of them back where it stood and takes the hide gadgets off the
/// screen's windows.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and the layers' locks.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The window, its RastPort and its port are gone. Every message the
/// program took off the port must have been replied first.
///
/// NOTES:
/// A task that ends with windows open has them closed through this call,
/// on the task's end (`RemTask`'s end hooks).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenWindowTagList`, `HideControl`
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
    // The windows it took in come back first: the way back closes with
    // it, and one of them may be the window the activation goes to.
    if (w.more_flags & _window.WMF_HIDEHOST != 0) @import("_hide.zig").release(ib, s);
    const was_active = ib.active_window == w;
    if (was_active) {
        ib.active_window = null;
        // No window active: the screen says its own title again.
        if (s.title != s.default_title) {
            s.title = s.default_title;
            _screen.drawBar(ib, s);
        }
        // The default pointer, with no window active.
        @import("../input/pointer.zig").update(ib);
    }
    @import("../requester/_requester.zig").takeAll(ib, w);
    @import("../input/_input.zig").forget(ib, w);
    @import("../input/drag.zig").forget(ib, w);
    _gadget.detach(ib, w);
    ib.sys_base.Remove(@ptrCast(&w.node));
    _window.dropOpener(ib, w);
    dropPort(ib, w);
    reclaim(ib, w);
    // The gadgets' RastPort goes before the layer whose pixels it names.
    if (w.gi_rp) |gi_rp| ib.graphics_base.FreeRastPort(gi_rp);
    w.gi_rp = null;
    // Its layers fade out, a ghost's, and the input task deletes them
    // then; or they go now.
    if (!@import("_fade.zig").fadeOut(ib, w)) {
        if (w.inner_layer) |inner| ib.layers_base.DeleteLayer(inner);
        ib.layers_base.DeleteLayer(w.layer);
    }
    w.inner_layer = null;
    w.inner_rp = null;
    if (w.text_font) |font| ib.graphics_base.CloseFont(font);
    disposeParts(ib, w);
    const visitor = w.more_flags & _window.WMF_VISITOR != 0;
    ib.sys_base.FreeMem(w, @sizeOf(Window));
    repairScreen(ib, s);
    // The activation back where it was before: drawn once the screen is.
    if (was_active) if (_window.latest(s)) |before| _window.activate(ib, before);
    if (visitor) _screen.leave(ib, s);
}
