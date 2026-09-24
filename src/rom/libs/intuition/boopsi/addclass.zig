// SPDX-License-Identifier: MPL-2.0
//! AddClass: makes a class public.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const classes = intuition.classes;
const Class = classes.Class;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Makes a class public.
///
/// SYNOPSIS:
/// ```zig
/// fn AddClass(ib: *IntuitionBase, cl: *Class) void
/// ```
///
/// SINCE: 0.2. LVO -28.
///
/// INPUTS:
/// - `cl` - a class from `MakeClass`, its dispatcher already set.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// It goes on the front of the public list, where `FindClass` and
/// `NewObjectTagList` by name reach it. A private class (no name) and one
/// already on the list are left as they are.
///
/// CONTEXT:
/// - Waits: for the class list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Still the caller's; the list only points at it.
///
/// NOTES:
/// - It does not check the name again. `MakeClass` refused a taken name,
///   but two classes made with one name before either was added can both
///   be added, and the newer is found first.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemoveClass`, `FindClass`
///
/// EXAMPLES:
/// ```zig
/// ib.AddClass(cl);
/// ```
pub fn AddClass(ib: *IntuitionBase, cl: *Class) void {
    if (cl.id == null) return;
    const it = ib.iface();
    const list = it.LockClassList();
    defer it.UnlockClassList();
    if (cl.flags & classes.CLF_INLIST != 0) return;
    ib.sys_base.AddHead(@ptrCast(list), @ptrCast(&cl.dispatcher.node));
    cl.flags |= classes.CLF_INLIST;
}
