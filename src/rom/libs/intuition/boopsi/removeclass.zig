// SPDX-License-Identifier: MPL-2.0
//! RemoveClass: takes a class off the public list.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const classes = intuition.classes;
const Class = classes.Class;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Takes a class off the public list.
///
/// SYNOPSIS:
/// ```zig
/// fn RemoveClass(ib: *IntuitionBase, cl: *Class) void
/// ```
///
/// SINCE: 0.2. LVO -32.
///
/// INPUTS:
/// - `cl` - the class. One not on the list is left alone.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Objects of it that exist are untouched and keep working; it simply can
/// no longer be found by name.
///
/// CONTEXT:
/// - Waits: for the class list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's, as before.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddClass`, `FreeClass`
///
/// EXAMPLES:
/// ```zig
/// ib.RemoveClass(cl);
/// ```
pub fn RemoveClass(ib: *IntuitionBase, cl: *Class) void {
    const it = ib.iface();
    _ = it.LockClassList();
    defer it.UnlockClassList();
    if (cl.flags & classes.CLF_INLIST == 0) return;
    ib.sys_base.Remove(@ptrCast(&cl.dispatcher.node));
    cl.flags &= ~classes.CLF_INLIST;
}
