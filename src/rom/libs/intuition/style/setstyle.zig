// SPDX-License-Identifier: MPL-2.0
//! SetStyle: a screen's style, or the system's, replaced while it is open.

const sdk = @import("sdk");
const utility = sdk.utility;
const wn = sdk.intuition.windows;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _style = @import("_style.zig");
const _window = @import("../window/_window.zig");
const _screen = @import("../screen/_screen.zig");
const _gadget = @import("../gadget/_gadget.zig");
const Window = _window.Window;
const Screen = _screen.Screen;

/// A screen's style, or the system's, replaced - and every window it
/// reaches drawn again in it.
///
/// SYNOPSIS:
/// ```zig
/// fn SetStyle(ib: *IntuitionBase, screen: ?*Screen,
///     tags: ?[*]const TagItem) bool
/// ```
///
/// SINCE: 0.23. LVO -488.
///
/// INPUTS:
/// - `screen` - the screen whose own style it is, as `SA_Style` gives one
///   at open; null for the system's style.
/// - `tags` - the style, a tag list as `SA_Style` takes; null, or one
///   with no property in it, for none.
///
/// RESULT:
/// True when the style is in place; false when there was no memory for
/// it, and then the one before is kept.
///
/// BEHAVIOR:
/// The list is read once, as `SA_Style`'s is, and may go once the call
/// returns. **The system's style** is asked after a screen's own and
/// before the system's default, so it changes the look of every screen
/// at once, those already open among them, and of every screen opened
/// after; a screen's own style still wins over it. **A screen's own**
/// replaces what `SA_Style`, or an earlier call, gave that screen.
///
/// Every window on the screens it reaches is then drawn again: its
/// gadgets laid out - a border or a padding may have changed what fits -
/// its frame and its gadgets drawn, and the screen's bar. Each such window
/// that listens for `IDCMP_NEWPREFS` hears it, for what it draws itself.
///
/// CONTEXT:
/// - Waits: yes - for intuition's lock, and for the layers it draws in.
/// - Interrupts: no.
/// - Forbid: must not be held. The style is changed under a Forbid of the
///   call's own.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The list stays the caller's; intuition keeps its own copy, and frees
/// the one it replaces. A screen's style is freed when the screen
/// closes.
///
/// NOTES:
/// - What a program read with `GetStyleAttr(STYLE_BackgroundFill)` points
///   into the style it came from, and is good only until that style is
///   replaced.
/// - With no screen, what `SetPrefs` does with `IPREFS_Style` - which
///   `C:SetPrefs` gives from `ENV:Sys/style.prefs`.
///
/// BUGS:
/// - A window keeps the border sizes it opened with: a style whose window
///   border is wider or narrower than the one before shows it only in
///   windows opened after.
/// - A gadget drawn smaller than before leaves what was outside it until
///   the window is drawn again for some other reason.
///
/// SEE ALSO:
/// `SA_Style`, `GA_Style`, `DrawPart`, `GetStyleAttr`, `SetPrefs`
///
/// EXAMPLES:
/// ```zig
/// // Every screen's buttons with a blue line round them.
/// const blue = [_]TagItem{
///     .{ .tag = style.STYLE_Part, .data = style.PART_MAIN },
///     .{ .tag = style.STYLE_Border, .data = style.BORDER_FLAT },
///     .{ .tag = style.STYLE_BorderRGB, .data = 0xFF3A6EA5 },
///     .{},
/// };
/// if (!ib.SetStyle(null, &blue)) return dos.RETURN_FAIL;
///
/// // And back to the default.
/// _ = ib.SetStyle(null, null);
/// ```
pub fn SetStyle(ib: *IntuitionBase, screen: ?*Screen, tags: ?[*]const TagItem) bool {
    const kept = _style.keep(ib, tags);
    if (kept == null and _style.names(ib, tags)) return false;

    // In place before the old one goes: a lookup holds Forbid for as long
    // as it reads a style, so once this Forbid is let go nothing reads the
    // old one any more.
    ib.sys_base.Forbid();
    const old = if (screen) |s| @constCast(s.draw_info.style) else ib.system_style;
    if (screen) |s| s.draw_info.style = kept else ib.system_style = kept;
    ib.style_serial +%= 1;
    ib.sys_base.Permit();
    _style.drop(ib, old);

    _window.lock(ib);
    defer _window.unlock(ib);
    var node = ib.screen_list.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const s: *Screen = @ptrCast(@alignCast(n));
        if (screen != null and screen != s) continue;
        redraw(ib, s);
    }
    return true;
}

/// A screen drawn again in its style: its bar, and every window on it.
fn redraw(ib: *IntuitionBase, s: *Screen) void {
    _screen.drawBar(ib, s);
    var node = s.windows.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const w: *Window = @ptrCast(@alignCast(n));
        _gadget.layout(ib, w, w.gadgets, false);
        _window.drawBorder(ib, w);
        _gadget.renderAll(ib, w);
        _window.send(ib, w, wn.IDCMP_NEWPREFS, 0);
    }
}
