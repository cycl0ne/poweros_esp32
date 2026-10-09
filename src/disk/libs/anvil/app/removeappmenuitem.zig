// SPDX-License-Identifier: MIT
//! RemoveAppMenuItem: an item taken out of the Tools menu.

const sdk = @import("sdk");
const anvil = sdk.anvil;
const AnvilBase = @import("../anvil_base.zig").AnvilBase;
const _app = @import("_app.zig");

/// Removes an item a program added to the Tools menu.
///
/// SYNOPSIS:
/// ```zig
/// fn RemoveAppMenuItem(base: *AnvilBase, app: ?*anvil.AppMenuItem) bool
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `app` - what `AddAppMenuItem` gave; null does nothing.
///
/// RESULT:
/// True when it was on the desktop's list; false for null, for one
/// removed already, and once the desktop has ended.
///
/// BEHAVIOR:
/// Nothing more is sent for the item once the call returns; the desktop
/// takes it out of the menu soon after. Messages sent before are still on
/// the program's port, to be replied.
///
/// CONTEXT:
/// - Waits: yes, for the desktop's list.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: any task.
///
/// OWNERSHIP:
/// The handle is gone; the port is the program's again.
///
/// NOTES:
/// The program replies what is left on its port before it deletes it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddAppMenuItem`
///
/// EXAMPLES:
/// ```zig
/// _ = ab.RemoveAppMenuItem(app);
/// ```
pub fn RemoveAppMenuItem(base: *AnvilBase, app: ?*anvil.AppMenuItem) bool {
    return _app.remove(base, app, .menu_item);
}
