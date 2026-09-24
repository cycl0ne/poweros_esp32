// SPDX-License-Identifier: MPL-2.0
//! FindClass: finds a public class by name.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const classes = intuition.classes;
const Class = classes.Class;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _boopsi = @import("_boopsi.zig");
const sameName = _boopsi.sameName;

/// Finds a public class by name.
///
/// SYNOPSIS:
/// ```zig
/// fn FindClass(ib: *IntuitionBase, class_id: [*:0]const u8) ?*Class
/// ```
///
/// SINCE: 0.2. LVO -36.
///
/// INPUTS:
/// - `class_id` - the name, compared exactly.
///
/// RESULT:
/// The class, or null.
///
/// BEHAVIOR:
/// It looks only at the public list; a private class is never found.
///
/// CONTEXT:
/// - Waits: for the class list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The class stays its owner's. It can be freed the moment the list is let
/// go, so an answer is only good while the caller holds `LockClassList`.
///
/// NOTES:
/// - To make an object of a public class, name it to `NewObjectTagList`,
///   which finds it and keeps it from going away in one step.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockClassList`, `NewObjectTagList`
///
/// EXAMPLES:
/// ```zig
/// _ = ib.LockClassList();
/// defer ib.UnlockClassList();
/// const exists = ib.FindClass("imageclass") != null;
/// ```
pub fn FindClass(ib: *IntuitionBase, class_id: [*:0]const u8) ?*Class {
    const it = ib.iface();
    const list = it.LockClassList();
    defer it.UnlockClassList();

    var node = list.head;
    while (node) |n| : (node = n.succ) {
        // The tail sentinel is the node whose successor is null.
        if (n.succ == null) break;
        // The dispatcher is a class's first field and its node is the
        // hook's first, so a node on this list is a class.
        const cl: *Class = @ptrCast(@alignCast(n));
        if (sameName(cl.id.?, class_id)) return cl;
    }
    return null;
}
