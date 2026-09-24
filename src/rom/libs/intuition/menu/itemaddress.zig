// SPDX-License-Identifier: MPL-2.0
//! ItemAddress: the item a menu number names.

const sdk = @import("sdk");
const Menu = sdk.intuition.Menu;
const MenuItem = sdk.intuition.MenuItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _menu = @import("_menu.zig");

/// The item a menu number names.
///
/// SYNOPSIS:
/// ```zig
/// fn ItemAddress(ib: *IntuitionBase, menu_strip: ?*Menu, menu_number: u32) ?*MenuItem
/// ```
///
/// SINCE: 0.12. LVO -276.
///
/// INPUTS:
/// - `menu_strip` - the strip, or null.
/// - `menu_number` - a menu number: what IDCMP_MENUPICK carries in `code`,
///   or an item's `next_select`.
///
/// RESULT:
/// The subitem the number names, or the item when it names no subitem;
/// null when it names only a title, or none - `MENUNULL` - or one the
/// strip does not have.
///
/// BEHAVIOR:
/// The number is taken apart with `MENUNUM`, `ITEMNUM` and `SUBNUM` and the
/// strip walked to that menu, item and subitem. Nothing is changed.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no: the strip is the caller's, and a task's.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The item is the strip's, which is the caller's.
///
/// NOTES:
/// A program reads what was picked by following the chain:
/// `ItemAddress` of the message's code, then of that item's `next_select`,
/// until `MENUNULL`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetMenuStrip`, `sdk.intuition.menus.MENUNUM`
///
/// EXAMPLES:
/// ```zig
/// var number = message.code;
/// while (number != MENUNULL) {
///     const item = ib.ItemAddress(&project_menu, number) orelse break;
///     picked(number);
///     number = item.next_select;
/// }
/// ```
pub fn ItemAddress(_: *IntuitionBase, menu_strip: ?*Menu, menu_number: u32) ?*MenuItem {
    const item = _menu.grabItem(_menu.grabMenu(menu_strip, menu_number), menu_number) orelse return null;
    return _menu.grabSub(item, menu_number) orelse item;
}
