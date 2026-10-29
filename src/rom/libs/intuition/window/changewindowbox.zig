// SPDX-License-Identifier: MPL-2.0
//! ChangeWindowBox: moves and sizes a window at once.

const sdk = @import("sdk");
const exec = sdk.exec;
const intuition = sdk.intuition;
const wn = intuition.windows;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _gadget = @import("../gadget/_gadget.zig");
const _input = @import("../input/_input.zig");
const ie = sdk.devices.inputevent;
const _window = @import("_window.zig");
const Window = _window.Window;
const drawBorder = _window.drawBorder;
const lock = _window.lock;
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
/// changed, the border is drawn where it now is, and so is every gadget;
/// where a gadget that moves with an edge was, and - in a window that is
/// not GimmeZeroZero - where the right and bottom border were, the
/// window's ground is put back. All of it is drawn into pictures kept
/// aside, a strip of the border or an area at a time, and put on the
/// window in one copy each, so nothing of it is cleared on the window
/// first. Where the ground went back is the window's damage, as is what
/// the size added: what the program drew there is gone. The program is
/// told `IDCMP_NEWSIZE`; either way it is told `IDCMP_CHANGEWINDOW`.
/// Whatever the change uncovered is repaired, and the damage is the
/// program's `IDCMP_REFRESHWINDOW`. When a layout in the window then needs
/// more room than the size gives it - a row that wraps went deeper at the
/// new width - the window grows to that room in a second step, as far as
/// the screen lets it, and the program hears a second `IDCMP_NEWSIZE`.
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
///   is new inside it is the background, and damage: redraw everything
///   on IDCMP_NEWSIZE, or only the damage on the IDCMP_REFRESHWINDOW that
///   follows.
/// - While the user sizes a window with its size gadget, each step waits
///   until the program has replied the last step's `IDCMP_NEWSIZE` - for
///   three ticks at most - and a frame has passed since the last step
///   began. A program that redraws on it and replies after drawing has
///   the window follow its drawing, a step at a time.
/// - On a composed screen such a step is shown once it is drawn: the new
///   size and what is drawn in the window at it, by intuition and then by
///   the program, are gathered and reach the display together when the
///   program has replied (or the three ticks are up). Until then the
///   display shows the window as it was. Gadgets the program had
///   refreshed with `QueueGadgetRefresh` before replying are drawn into it
///   first.
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
    const sized = dw != 0 or dh != 0;
    // A step of the user's sizing is shown once drawn, its new size with
    // it and its program's part included: gathered from before its layers
    // are sized. Any other change hands on what a step gathered first.
    _input.beginChange(ib, window, sized);

    // Where the gadgets that move with an edge are now: what the size
    // will leave behind, while their boxes are still measured against the
    // old size. Nothing is cleared yet - it is painted over afterwards,
    // with what ends up there.
    var behind: _gadget.Behind = .{};
    if (sized) _gadget.leftBehind(ib, window, &behind);
    // A GimmeZeroZero window's interior goes with it: its layer moves and
    // sizes with the border's, by the same amounts.
    if (!ib.layers_base.MoveSizeLayer(window.layer, dx, dy, dw, dh)) {
        // The layer would not move, so the window stays as it was.
        var why: usize = 0;
        const asked = [_]sdk.utility.TagItem{ .{ .tag = sdk.layers.LATAG_GetLastError, .data = @intFromPtr(&why) }, .{} };
        ib.layers_base.GetLayerAttrs(window.layer, &asked);
        exec.kprintf(ib.sys_base, "window: MoveSizeLayer refused move %d,%d size %d,%d: error %d, %ld bytes free\n", .{
            dx,                                             dy,
            dw,                                             dh,
            @as(i32, @truncate(@as(isize, @bitCast(why)))), @as(u64, ib.sys_base.AvailMem(sdk.exec.MEMF_ANY)),
        });
        _input.settleGather(ib);
        return;
    }
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
    // class that arranges something of its own - and a layout says again
    // what it needs, for `fitLayout` below.
    if (sized) {
        window.layout_width = 0;
        window.layout_height = 0;
        _gadget.layout(ib, window, window.gadgets, false);
    }

    if (sized) {
        // Where the right and bottom border were is inside the window now,
        // and gets the window's ground. A GimmeZeroZero window's interior
        // is a layer of its own, which paints its new part itself.
        if (window.inner_layer == null) {
            const inner_right = @min(old_w, new_w - window.border_right);
            const inner_bottom = @min(old_h, new_h - window.border_bottom);
            behind.add(.{ .min_x = old_w - window.border_right, .min_y = window.border_top, .max_x = inner_right, .max_y = inner_bottom });
            behind.add(.{ .min_x = window.border_left, .min_y = old_h - window.border_bottom, .max_x = inner_right, .max_y = inner_bottom });
        }
        drawBorder(ib, window);
        _gadget.redrawRoom(ib, window, &behind);
        _input.sendNewSize(ib, window);
        _input.windowEvent(ib, window, ie.IECLASS_EVENT, ie.IECODE_NEWSIZE);
    }
    send(ib, window, wn.IDCMP_CHANGEWINDOW, 0);
    // A size has drawn the window's border and its room whole just now:
    // what it gained is not drawn over a second time.
    _window.repairScreenAfter(ib, s, if (sized) window else null);
    // A row that wraps may need more height at the new width than the
    // window has: the window grows to it, a second step of its own.
    if (sized) _window.fitLayout(ib, window);
    // Shown now, unless the program's answer is awaited.
    _input.settleGather(ib);
}
