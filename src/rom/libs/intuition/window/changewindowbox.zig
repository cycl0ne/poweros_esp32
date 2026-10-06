// SPDX-License-Identifier: MPL-2.0
//! ChangeWindowBox: moves and sizes a window at once.

const sdk = @import("sdk");
const exec = sdk.exec;
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
/// and no larger than the screen. The place keeps it on the screen - or,
/// while windows may hang past the screen's edges (`IPREFS_OffScreen`),
/// keeps enough of it there to take hold of again: its top never above
/// the screen's, 64 pixels of its width across, and its title bar above
/// the bottom. A box that does not fit where it is given is moved. When the size
/// changed, what was the right and bottom border is cleared to the
/// background and the border drawn where it now is, and the program is
/// told `IDCMP_NEWSIZE`; either way it is told `IDCMP_CHANGEWINDOW`.
/// Whatever the change uncovered is repaired.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and the layers' locks.
/// - Interrupts: no.
/// - Locks: none needed.
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
    const place = _window.legalPlace(ib, window, left, top, new_w, new_h);
    const new_l = place.left;
    const new_t = place.top;
    const dx = new_l - window.left;
    const dy = new_t - window.top;
    const dw = new_w - window.width;
    const dh = new_h - window.height;
    if (dx == 0 and dy == 0 and dw == 0 and dh == 0) return;

    // What is about to move is cleared where it is now, before the layer
    // is told, because afterwards its old place is no longer the window's
    // to draw in.
    const cleared = dw != 0 or dh != 0;
    if (cleared) _gadget.clearRelative(ib, window);
    if (!ib.layers_base.MoveSizeLayer(window.layer, dx, dy, dw, dh)) {
        // The layer would not move, so the window is the size it was -
        // but its gadgets have just been cleared off it. They are put
        // back: a window that cannot be resized is a window that stays
        // as it was, not an empty one that no later drawing repairs,
        // since nothing else will draw it again until its program has
        // some reason to.
        if (cleared) {
            drawBorder(ib, window);
            _gadget.renderAll(ib, window);
        }
        var why: usize = 0;
        const asked = [_]sdk.utility.TagItem{ .{ .tag = sdk.layers.LATAG_GetLastError, .data = @intFromPtr(&why) }, .{} };
        ib.layers_base.GetLayerAttrs(window.layer, &asked);
        exec.kprintf(ib.sys_base, "window: MoveSizeLayer refused move %d,%d size %d,%d: error %d, %ld bytes free\n", .{
            dx,                                             dy,
            dw,                                             dh,
            @as(i32, @truncate(@as(isize, @bitCast(why)))), @as(u64, ib.sys_base.AvailMem(sdk.exec.MEMF_ANY)),
        });
        return;
    }
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
