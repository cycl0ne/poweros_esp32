// SPDX-License-Identifier: MPL-2.0
//! FreeMenus: gives back what CreateMenusA made.

const sdk = @import("sdk");
const Menu = sdk.intuition.Menu;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const createmenusa = @import("createmenusa.zig");

/// Gives back a strip, or a panel's items, that CreateMenusA made.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeMenus(ib: *IntuitionBase, menu: ?*Menu) void
/// ```
///
/// SINCE: 0.17. LVO -440.
///
/// INPUTS:
/// - `menu` - what CreateMenusA answered, or null, which does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The separators' rule images are disposed of and the one allocation
/// given back. The table's words and images are not touched: they were
/// never copied.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The strip is gone; it must be off every window first (`ClearMenuStrip`).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateMenusA`, `ClearMenuStrip`
///
/// EXAMPLES:
/// ```zig
/// ib.ClearMenuStrip(window);
/// ib.FreeMenus(strip);
/// ```
pub fn FreeMenus(ib: *IntuitionBase, menu: ?*Menu) void {
    const first = menu orelse return;
    createmenusa.freeAll(ib, createmenusa.headerOf(first));
}
