// SPDX-License-Identifier: MIT
//! RemoveAppWindow: a window taken off the desktop's list.

const sdk = @import("sdk");
const anvil = sdk.anvil;
const AnvilBase = @import("../anvil_base.zig").AnvilBase;
const _app = @import("_app.zig");

/// Removes a window files could be dropped on.
///
/// SYNOPSIS:
/// ```zig
/// fn RemoveAppWindow(base: *AnvilBase, app: ?*anvil.AppWindow) bool
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `app` - what `AddAppWindow` gave; null does nothing.
///
/// RESULT:
/// True when it was on the desktop's list; false for null, for one
/// removed already, and once the desktop has ended, which lets go of
/// everything added to it.
///
/// BEHAVIOR:
/// Nothing more is sent for the window once the call returns: icons let
/// go over it fly back again. Messages sent before are still on the
/// program's port, to be replied.
///
/// CONTEXT:
/// - Waits: yes, for the desktop's list.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: any task.
///
/// OWNERSHIP:
/// The handle is gone; the window and the port are the program's again.
///
/// NOTES:
/// The program replies what is left on its port before it deletes it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddAppWindow`
///
/// EXAMPLES:
/// ```zig
/// _ = ab.RemoveAppWindow(app);
/// while (sys.GetMsg(port)) |message| sys.ReplyMsg(message);
/// sys.DeleteMsgPort(port);
/// ```
pub fn RemoveAppWindow(base: *AnvilBase, app: ?*anvil.AppWindow) bool {
    return _app.remove(base, app, .window);
}
