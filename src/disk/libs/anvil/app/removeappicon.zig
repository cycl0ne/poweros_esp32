// SPDX-License-Identifier: MIT
//! RemoveAppIcon: a program's icon taken off the desktop.

const sdk = @import("sdk");
const anvil = sdk.anvil;
const AnvilBase = @import("../anvil_base.zig").AnvilBase;
const _app = @import("_app.zig");

/// Removes an icon a program added.
///
/// SYNOPSIS:
/// ```zig
/// fn RemoveAppIcon(base: *AnvilBase, app: ?*anvil.AppIcon) bool
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `app` - what `AddAppIcon` gave; null does nothing.
///
/// RESULT:
/// True when it was on the desktop's list; false for null, for one
/// removed already, and once the desktop has ended.
///
/// BEHAVIOR:
/// Nothing more is sent for the icon once the call returns; the desktop
/// takes it off its ground soon after. Messages sent before are still on
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
/// `AddAppIcon`
///
/// EXAMPLES:
/// ```zig
/// _ = ab.RemoveAppIcon(app);
/// ```
pub fn RemoveAppIcon(base: *AnvilBase, app: ?*anvil.AppIcon) bool {
    return _app.remove(base, app, .icon);
}
