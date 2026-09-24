// SPDX-License-Identifier: MPL-2.0
//! FreeClass: frees a class.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const classes = intuition.classes;
const Class = classes.Class;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Frees a class.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeClass(ib: *IntuitionBase, cl: ?*Class) bool
/// ```
///
/// SINCE: 0.2. LVO -24.
///
/// INPUTS:
/// - `cl` - the class, or null.
///
/// RESULT:
/// True when it was freed, or `cl` was null. False while any object of it
/// or any class made from it still exists.
///
/// BEHAVIOR:
/// It is taken off the public list whether or not it can be freed, so no
/// new object is made of it by name. Freed, its superclass's subclass
/// count comes down.
///
/// CONTEXT:
/// - Waits: for the class list's semaphore.
/// - Interrupts: no; it frees memory.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// On true the class's memory is gone; on false the caller still has the
/// class, and must keep its dispatcher's code where it is.
///
/// NOTES:
/// - A library that implements a class refuses to be expunged while this
///   answers false: its dispatcher is still reachable.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MakeClass`, `RemoveClass`
///
/// EXAMPLES:
/// ```zig
/// if (!ib.FreeClass(cl)) return null; // still in use: stay loaded
/// ```
pub fn FreeClass(ib: *IntuitionBase, cl: ?*Class) bool {
    const c = cl orelse return true;
    const it = ib.iface();
    it.RemoveClass(c);

    _ = it.LockClassList();
    defer it.UnlockClassList();
    if (c.subclass_count != 0 or c.object_count != 0) return false;
    if (c.super) |s| s.subclass_count -= 1;
    ib.sys_base.FreeMem(c, @sizeOf(Class));
    return true;
}
