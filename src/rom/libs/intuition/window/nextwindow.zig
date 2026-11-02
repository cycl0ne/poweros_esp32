// SPDX-License-Identifier: MPL-2.0
//! NextWindow: the windows of a screen, front to back.

const sdk = @import("sdk");
const layers = sdk.layers;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const lock = _window.lock;
const unlock = _window.unlock;
const _screen = @import("../screen/_screen.zig");

/// The window behind another, for a walk down a screen's depth order.
///
/// SYNOPSIS:
/// ```zig
/// fn NextWindow(ib: *IntuitionBase, after: ?*Window) ?*Window
/// ```
///
/// SINCE: 0.80. LVO -536.
///
/// INPUTS:
/// - `after` - the window to go on from, or null to start at the front.
///
/// RESULT:
/// The window immediately behind `after` on `after`'s screen, or - for a
/// null `after` - the frontmost window of the screen in front. Null past
/// the backmost window, and while no screen is open.
///
/// BEHAVIOR:
/// The screen's depth order is walked, front to back, so a walk from null
/// sees every window of that screen once, from the one in front to the
/// one at the back. The order is the one a press sees: the window in
/// front of another is the one that covers it. A window that stays in
/// front (`WA_StayInFront`) comes before the ordinary ones and a backdrop
/// window after them all.
///
/// CONTEXT:
/// - Waits: yes, for the screens' semaphore.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The windows are their openers'. They stay open only while the caller
/// holds `LockIBase`, which also keeps the order still: without it the
/// window the answer names may close, and the walk may see a window
/// twice or not at all.
///
/// NOTES:
/// - Cycling the windows is the frontmost one sent to the back and the
///   new frontmost activated, rather than a walk: `WindowToBack` changes
///   the order the walk reads.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ActiveWindow`, `WindowToFront`, `WindowToBack`, `FrontScreen`,
/// `LockIBase`
///
/// EXAMPLES:
/// ```zig
/// const held = ib.LockIBase(0);
/// defer ib.UnlockIBase(held);
/// var window = ib.NextWindow(null);
/// while (window) |w| : (window = ib.NextWindow(w)) count += 1;
/// ```
pub fn NextWindow(ib: *IntuitionBase, after: ?*Window) ?*Window {
    lock(ib);
    defer unlock(ib);
    const screen = if (after) |w| w.screen else (_screen.frontmost(ib) orelse return null);
    // The depth order runs from the screen's ground forward, back to
    // front: the window behind `after` is the last one found before it,
    // and the frontmost is the last one found of all. A window's other
    // layers - its interior, its requesters - name it again and are
    // passed over.
    var last: ?*Window = null;
    var at: ?*layers.Layer = screen.ground;
    while (at) |layer| : (at = _window.layerInFront(ib, layer)) {
        const w = _window.windowOfLayer(screen, layer) orelse continue;
        if (w == last) continue;
        if (after != null and w == after.?) return last;
        last = w;
    }
    return if (after == null) last else null;
}
