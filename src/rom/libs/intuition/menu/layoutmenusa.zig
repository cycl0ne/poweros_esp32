// SPDX-License-Identifier: MPL-2.0
//! LayoutMenusA: places a strip from CreateMenusA on a screen.

const sdk = @import("sdk");
const utility = sdk.utility;
const intuition = sdk.intuition;
const Menu = intuition.Menu;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("../screen/_screen.zig");
const _menu = @import("_menu.zig");

/// Places every title, item and subitem of a strip CreateMenusA made, for
/// a screen.
///
/// SYNOPSIS:
/// ```zig
/// fn LayoutMenusA(ib: *IntuitionBase, menu: *Menu, screen: *Screen, tags: ?[*]const TagItem) bool
/// ```
///
/// SINCE: 0.17. LVO -444.
///
/// INPUTS:
/// - `menu` - the first title of a strip from CreateMenusA.
/// - `screen` - the screen whose windows will show it.
/// - `tags` - `GTMN_Font`, the items' font, the screen's unless given;
///   `GTMN_FrontPen`, their colour, the screen's `BARDETAILPEN` unless
///   given; `GTMN_Checkmark` and `GTMN_AmigaKey`, a window's own images
///   in place of the screen's, for their widths.
///
/// RESULT:
/// True.
///
/// BEHAVIOR:
/// The titles go along the bar from its left, each as wide as its words
/// in the screen's font and the bar's trim either side, a character apart.
/// Each panel's items go in a column from under the bar at its title, as
/// tall as a line of the font and a row (never less than nine), as wide as
/// the widest item's words - in from the left by the checkmark's width for
/// a `CHECKIT` item - and the widest shortcut, words at the right, or "»"
/// with the Amiga key and a character's gap; separators six rows. A panel
/// taller than the screen goes on in further columns, and one that would
/// run off the screen's right is moved left. Subitems go beside their
/// item, three quarters of the way across it and a row higher, higher
/// still to fit on the screen.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The strip is still the caller's. Its places are written, and into each
/// item text's runs their `IT_Left`, `IT_FrontPen` and `IT_Font`: the
/// runs CreateMenusA makes are writable and have all three, and a run
/// without one of them keeps what it says.
///
/// NOTES:
/// Laid out again after a window's font or screen changes, before the
/// strip is set again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateMenusA`, `LayoutMenuItemsA`, `SetMenuStrip`
///
/// EXAMPLES:
/// ```zig
/// const strip = ib.CreateMenusA(&table, null) orelse return;
/// _ = ib.LayoutMenusA(strip, screen, null);
/// _ = ib.SetMenuStrip(window, strip);
/// ```
pub fn LayoutMenusA(ib: *IntuitionBase, menu: *Menu, screen: *intuition.Screen, tags: ?[*]const TagItem) bool {
    const s: *_screen.Screen = @ptrCast(@alignCast(screen));
    const layout = _menu.Layout.of(ib, s, tags);
    var start: i32 = 0;
    var each: ?*Menu = menu;
    while (each) |m| : (each = m.next_menu) {
        m.left = start;
        const words: i32 = if (m.name) |name| measured: {
            const run = intuition.text.plainRun(name, s.font);
            break :measured ib.iface().IntuiTextLength(&run);
        } else 0;
        // The title's highlight reaches the bar's trim either side of it.
        m.width = words + 2 * (_screen.bar_left - _screen.bar_border);
        _menu.sizeItems(&layout, m.first_item);
        _menu.placeItems(&layout, m.first_item, 0, 0, _screen.bar_left + m.left, s.bar_height, m.width, false);
        start += m.width + layout.font_x;
    }
    return true;
}
