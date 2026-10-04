// SPDX-License-Identifier: MPL-2.0
//! SetScreenPens: a screen's pens, or the system's, replaced while the
//! screens are open, and everything they reach painted again.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;
const sc = sdk.intuition.screens;
const wn = sdk.intuition.windows;
const ie = sdk.devices.inputevent;
const TagItem = sdk.utility.TagItem;
const Pen = graphics.Pen;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const _screen = @import("_screen.zig");
const _gadget = @import("../gadget/_gadget.zig");
const Window = _window.Window;
const Screen = _screen.Screen;

/// A screen's pens, or the system's, replaced - and every screen it
/// reaches painted again in them.
///
/// SYNOPSIS:
/// ```zig
/// fn SetScreenPens(ib: *IntuitionBase, screen: ?*Screen,
///     pens: ?[*]const Pen) void
/// ```
///
/// SINCE: 0.26. LVO -496.
///
/// INPUTS:
/// - `screen` - the screen whose own pens they are, as `SA_Pens` gives
///   them at open; null for the system's.
/// - `pens` - `NUMDRIPENS` colours, by the `DrawInfo` pens' indexes, read
///   and copied; null for the system's pens (a screen) or the built-in
///   ones (the system).
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// **The system's pens** are what a screen opened without `SA_Pens`,
/// `SA_DetailPen` or `SA_BlockPen` takes: every such screen, those already
/// open among them, and every one opened after. **A screen's own**
/// replaces its pens alone, and then it keeps them whatever the system's
/// become; given null, it follows the system's again.
///
/// Every screen it reaches is then painted again: its ground, its bar,
/// and every window on it - its inside in the new background, its border
/// and its gadgets. A console in a window draws its text again; each
/// window that listens for `IDCMP_NEWPREFS` hears it, for what its
/// program draws itself, which the paint has cleared.
///
/// CONTEXT:
/// - Waits: yes - for intuition's lock, and for the layers it draws in.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pens stay the caller's; the screen keeps a copy.
///
/// NOTES:
/// - With no screen, what `SetPrefs` does with `IPREFS_Pens` - which
///   `C:SetPrefs` gives from `ENV:Sys/palette.prefs`.
/// - A style that gives colours of its own (`STYLE_BackgroundRGB` and the
///   rest) keeps them: only what is drawn in pens changes.
///
/// BUGS:
/// - A program that draws in its window and does not listen for
///   `IDCMP_NEWPREFS` shows the new background where it drew until it
///   draws again.
///
/// SEE ALSO:
/// `SA_Pens`, `GetScreenDrawInfo`, `SetStyle`, `SetPrefs`
///
/// EXAMPLES:
/// ```zig
/// // A darker ground for every screen, the rest as they are.
/// var pens: [sc.NUMDRIPENS]Pen = (ib.GetScreenDrawInfo(screen)).pens[0..sc.NUMDRIPENS].*;
/// pens[sc.BACKGROUNDPEN] = graphics.penRGB(0x80, 0x84, 0x88);
/// ib.SetScreenPens(null, &pens);
/// ```
pub fn SetScreenPens(ib: *IntuitionBase, screen: ?*Screen, pens: ?[*]const Pen) void {
    _window.lock(ib);
    defer _window.unlock(ib);
    if (screen) |s| {
        s.own_pens = pens != null;
        s.pens = if (pens) |given| given[0..sc.NUMDRIPENS].* else ib.system_pens;
    } else {
        // Read by a prefs copy under the look's lock.
        ib.sys_base.AcquireLock(&ib.look_lock);
        ib.system_pens = if (pens) |given| given[0..sc.NUMDRIPENS].* else _screen.default_pens;
        ib.sys_base.ReleaseLock(&ib.look_lock);
    }
    // What was drawn and kept in the old pens is old.
    ib.style_serial +%= 1;
    var node = ib.screen_list.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const s: *Screen = @ptrCast(@alignCast(n));
        if (screen) |only| {
            if (s != only) continue;
        } else {
            if (s.own_pens) continue;
            s.pens = ib.system_pens;
        }
        paint(ib, s);
    }
}

/// A screen painted again in its pens: its ground, its bar, every window.
fn paint(ib: *IntuitionBase, s: *Screen) void {
    const gb = ib.graphics_base;
    const lb = ib.layers_base;
    if (s.ground) |ground| {
        var rp: usize = 0;
        lb.GetLayerAttrs(ground, &[_]TagItem{ .{ .tag = layers.LATAG_GetRastPort, .data = @intFromPtr(&rp) }, .{} });
        if (rp != 0) gb.EraseRect(@ptrFromInt(rp), &.{ .max_x = s.width, .max_y = s.height });
    }
    _screen.drawBar(ib, s);
    var node = s.windows.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const w: *Window = @ptrCast(@alignCast(n));
        gb.EraseRect(w.rp, &.{ .max_x = w.width, .max_y = w.height });
        _window.drawBorder(ib, w);
        _gadget.renderAll(ib, w);
        _window.send(ib, w, wn.IDCMP_NEWPREFS, 0);
        // A console on it draws its text again; it is not the window's
        // program.
        @import("../input/_input.zig").windowEvent(ib, w, ie.IECLASS_EVENT, ie.IECODE_REFRESHWINDOW);
    }
}
