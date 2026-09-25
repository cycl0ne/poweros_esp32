// SPDX-License-Identifier: MPL-2.0
//! LayoutMenuItemsA: places one panel's items from CreateMenusA.

const sdk = @import("sdk");
const utility = sdk.utility;
const intuition = sdk.intuition;
const mn = intuition.menus;
const Menu = intuition.Menu;
const MenuItem = intuition.MenuItem;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("../screen/_screen.zig");
const _menu = @import("_menu.zig");

/// Places the items of one panel, and their subitems, that CreateMenusA
/// made from a table of items.
///
/// SYNOPSIS:
/// ```zig
/// fn LayoutMenuItemsA(ib: *IntuitionBase, first_item: *MenuItem, screen: *Screen, tags: ?[*]const TagItem) bool
/// ```
///
/// SINCE: 0.17. LVO -448.
///
/// INPUTS:
/// - `first_item` - the first item, as CreateMenusA answered it.
/// - `screen` - the screen whose windows will show it.
/// - `tags` - `GTMN_Menu`, the title they are the panel of, which says
///   where the panel starts and how wide it is at the least; and those of
///   `LayoutMenusA`.
///
/// RESULT:
/// True.
///
/// BEHAVIOR:
/// As `LayoutMenusA` places a panel's items. Without `GTMN_Menu` the panel
/// is taken to start at the bar's left and may be as narrow as its items.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The items are still the caller's; their places and the texts' fonts
/// and colours are written.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LayoutMenusA`, `CreateMenusA`
///
/// EXAMPLES:
/// ```zig
/// const items = ib.CreateMenusA(&more_items, null) orelse return;
/// const first: *intuition.MenuItem = @ptrCast(@alignCast(items));
/// menu.first_item = first;
/// _ = ib.LayoutMenuItemsA(first, screen, &.{ .{ .tag = mn.GTMN_Menu, .data = @intFromPtr(menu) }, .{} });
/// ```
pub fn LayoutMenuItemsA(ib: *IntuitionBase, first_item: *MenuItem, screen: *intuition.Screen, tags: ?[*]const TagItem) bool {
    const s: *_screen.Screen = @ptrCast(@alignCast(screen));
    const layout = _menu.Layout.of(ib, s, tags);
    const menu: ?*Menu = @ptrFromInt(ib.utility_base.GetTagData(mn.GTMN_Menu, 0, tags));
    const left: i32 = if (menu) |m| m.left else 2;
    const width: i32 = if (menu) |m| m.width else 0;
    _menu.sizeItems(&layout, first_item);
    _menu.placeItems(&layout, first_item, 0, 0, _screen.bar_left + left, s.bar_height, width, false);
    return true;
}
