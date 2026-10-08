// SPDX-License-Identifier: MPL-2.0
//! EndDrag: the drag let go of, and where.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const _input = @import("_input.zig");
const _misc = @import("../misc/_misc.zig");
const drag = @import("drag.zig");

/// How a picture flies back: this many steps, this far apart - a fifth of
/// a second in all.
const flyback_steps = 12;
const flyback_step_us = 16_667;

/// Ends a drag `BeginDrag` started, and says which window it ended over.
///
/// SYNOPSIS:
/// ```zig
/// fn EndDrag(ib: *IntuitionBase, window: *Window, flags: u32) ?*Window
/// ```
///
/// SINCE: 0.34. LVO -516.
///
/// INPUTS:
/// - `window` - the window that began the drag.
/// - `flags` - `DRAGF_FLYBACK` to fly the picture back to where the drag
///   began before it goes - a drop that was not taken; 0 to take it away
///   where it is.
///
/// RESULT:
/// The window under the pointer, where the drop is - the frontmost there,
/// which may be `window` itself or another program's; null when the
/// pointer is over no window (the screen's own ground or title bar), or
/// when `window` was not dragging.
///
/// BEHAVIOR:
/// With `DRAGF_FLYBACK` the picture leaves the pointer and moves back to
/// where it was taken hold of in a fifth of a second, easing in as it
/// arrives, the call returning once it has. Then it is taken off the
/// display. The window under the pointer is looked for on `window`'s
/// screen, at the pointer's place when the call is made; the point in it
/// is the pointer's place less the window's corner, which
/// `GetWindowAttrs` gives.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore; with `DRAGF_FLYBACK` for the
///   fifth of a second it flies.
/// - Interrupts: no.
/// - Locks: none needed; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The window answered is not the caller's: it may close at any time, and
/// a program that tells it of the drop does so through its own channels
/// (an AppWindow's port), not by touching it.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BeginDrag`, rtg.library's `MoveBoardOverlay`
///
/// EXAMPLES:
/// ```zig
/// const target = ib.EndDrag(window, if (taken) 0 else intuition.DRAGF_FLYBACK);
/// if (target == window) {} // dropped in its own window
/// ```
pub fn EndDrag(ib: *IntuitionBase, window: *Window, flags: u32) ?*Window {
    _window.lock(ib);
    const st = &ib.drag;
    if (st.window != window) {
        _window.unlock(ib);
        return null;
    }
    const s = window.screen;
    const place = _input.pointerOn(ib, s);
    const target = _input.windowAt(ib, s, place.x, place.y);
    const board = st.board;
    const from_x = if (board) |b| b.overlay_x else 0;
    const from_y = if (board) |b| b.overlay_y else 0;
    const to_x = st.start_x;
    const to_y = st.start_y;
    _window.unlock(ib);

    // The flight, outside the semaphore: intuition's task goes on while
    // the picture moves.
    if (flags & intuition.DRAGF_FLYBACK != 0) {
        if (board) |b| if (ib.rtg_base) |rb| {
            var step: i32 = 1;
            while (step <= flyback_steps) : (step += 1) {
                // Eased: fast away, slowing as it arrives.
                const left = flyback_steps - step;
                const part = flyback_steps * flyback_steps - left * left;
                const whole = flyback_steps * flyback_steps;
                rb.MoveBoardOverlay(b, from_x + @divTrunc((to_x - from_x) * part, whole), from_y + @divTrunc((to_y - from_y) * part, whole));
                _misc.wait(ib, flyback_step_us);
            }
        };
    }

    _window.lock(ib);
    defer _window.unlock(ib);
    if (ib.drag.window == window) drag.stop(ib);
    return target;
}
