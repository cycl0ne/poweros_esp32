// SPDX-License-Identifier: MPL-2.0
//! NextObject: walks a list of objects.

const sdk = @import("sdk");
const exec = sdk.exec;
const intuition = sdk.intuition;
const classes = intuition.classes;
const Object = classes.Object;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Walks a list of objects.
///
/// SYNOPSIS:
/// ```zig
/// fn NextObject(_: *IntuitionBase, state: *?*exec.MinNode) ?*Object
/// ```
///
/// SINCE: 0.2. LVO -64.
///
/// INPUTS:
/// - `state` - a node pointer the walk keeps its place in. Set it to the
///   list's `head` before the first call.
///
/// RESULT:
/// The next object on the list, or null at its end.
///
/// BEHAVIOR:
/// The place moves on before the object is handed back, so the object may
/// be taken off the list (`OM_REMOVE`) and disposed of before the next
/// call. This is the only way to read a list objects were put on with
/// `OM_ADDTAIL`: the node is in the header, not at the handle.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no; the list is the caller's to guard.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The objects stay where they were.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `intuition.classusr.OM_ADDTAIL`, `intuition.classusr.OM_REMOVE`
///
/// EXAMPLES:
/// ```zig
/// var at = members.head;
/// while (ib.NextObject(&at)) |member| ib.DisposeObject(member);
/// ```
pub fn NextObject(_: *IntuitionBase, state: *?*exec.MinNode) ?*Object {
    const node = state.* orelse return null;
    // The tail sentinel has no successor: the walk is over.
    const succ = node.succ orelse return null;
    state.* = succ;
    // The node is the start of the object's header, and the handle is just
    // past the header.
    return @ptrFromInt(@intFromPtr(node) + @sizeOf(classes.ObjectHeader));
}
