// SPDX-License-Identifier: MPL-2.0
//! ChangeWindowBox: moves and sizes a window at once.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const wn = intuition.windows;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _gadget = @import("../gadget/_gadget.zig");
const ie = sdk.devices.inputevent;
const _window = @import("_window.zig");
const Window = _window.Window;
const drawBorder = _window.drawBorder;
const lock = _window.lock;
const repairScreen = _window.repairScreen;
const send = _window.send;
const unlock = _window.unlock;

/// Moves and sizes a window at once.
///
/// SYNOPSIS:
/// ```zig
/// fn ChangeWindowBox(ib: *IntuitionBase, window: *Window, left: i32,
///     top: i32, width: i32, height: i32) void
/// ```
///
/// SINCE: 0.5. LVO -152.
///
/// INPUTS:
/// - `window` - the window.
/// - `left`, `top`, `width`, `height` - the new box, on the screen.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The size is kept within the window's limits, never below its border,
/// and on the screen; the place keeps it on the screen. When the size
/// changed, what was the right and bottom border is cleared to the
/// background and the border drawn where it now is, and the program is
/// told `IDCMP_NEWSIZE`; either way it is told `IDCMP_CHANGEWINDOW`.
/// Whatever the change uncovered is repaired.
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
/// - A smart window keeps its contents through a move. After a size, what
///   is new inside it is the background: redraw on IDCMP_NEWSIZE.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MoveWindow`, `SizeWindow`
///
/// EXAMPLES:
/// ```zig
/// ib.ChangeWindowBox(window, 40, 40, 300, 200);
/// ```
pub fn ChangeWindowBox(ib: *IntuitionBase, window: *Window, left: i32, top: i32, width: i32, height: i32) void {
    const s = window.screen;
    lock(ib);
    defer unlock(ib);

    // Within its limits, never smaller than its border, and on its screen.
    const new_w = @min(@max(@max(width, window.min_width), window.border_left + window.border_right + 1), @min(window.max_width, s.width));
    const new_h = @min(@max(@max(height, window.min_height), window.border_top + window.border_bottom + 1), @min(window.max_height, s.height));
    const new_l = @max(@min(left, s.width - new_w), 0);
    const new_t = @max(@min(top, s.height - new_h), 0);
    const dx = new_l - window.left;
    const dy = new_t - window.top;
    const dw = new_w - window.width;
    const dh = new_h - window.height;
    if (dx == 0 and dy == 0 and dw == 0 and dh == 0) return;

    if (dw != 0 or dh != 0) _gadget.clearRelative(ib, window);
    if (!ib.layers_base.MoveSizeLayer(window.layer, dx, dy, dw, dh)) return;
    // The interior goes with it. Its border widths do not change, so it
    // moves by the same amount and grows by the same amount.
    if (window.inner_layer) |inner| _ = ib.layers_base.MoveSizeLayer(inner, dx, dy, dw, dh);
    const old_w = window.width;
    const old_h = window.height;
    window.left = new_l;
    window.top = new_t;
    window.width = new_w;
    window.height = new_h;
    // Its requesters go with it, cut again at its new edges.
    @import("../requester/_requester.zig").follow(ib, window);

    // The room every gadget is measured against has changed. Their boxes
    // are worked out afresh each time they are used, so this is for a
    // class that arranges something of its own.
    if (dw != 0 or dh != 0) _gadget.layout(ib, window, window.gadgets, false);

    if (dw != 0 or dh != 0) {
        // Where the right and bottom border were is inside the window now.
        // It is put back the way the window paints its ground, not filled
        // with the pen that usually matches it, since a window may have a
        // backfill of its own.
        const gb = ib.graphics_base;
        const inner_right = new_w - window.border_right;
        const inner_bottom = new_h - window.border_bottom;
        ib.layers_base.LockLayer(window.layer);
        const x0 = old_w - window.border_right;
        gb.EraseRect(window.rp, &.{
            .min_x = x0,
            .min_y = window.border_top,
            .max_x = @min(old_w, inner_right),
            .max_y = @min(old_h, inner_bottom),
        });
        const y0 = old_h - window.border_bottom;
        gb.EraseRect(window.rp, &.{
            .min_x = window.border_left,
            .min_y = y0,
            .max_x = @min(old_w, inner_right),
            .max_y = @min(old_h, inner_bottom),
        });
        ib.layers_base.UnlockLayer(window.layer);
        drawBorder(ib, window);
        _gadget.renderAll(ib, window);
        send(ib, window, wn.IDCMP_NEWSIZE, 0);
        @import("../input/_input.zig").windowEvent(ib, window, ie.IECLASS_EVENT, ie.IECODE_NEWSIZE);
    }
    send(ib, window, wn.IDCMP_CHANGEWINDOW, 0);
    repairScreen(ib, s);
}
