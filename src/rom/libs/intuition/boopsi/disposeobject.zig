// SPDX-License-Identifier: MPL-2.0
//! DisposeObject: frees an object.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const Object = classes.Object;
const Msg = classusr.Msg;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Frees an object.
///
/// SYNOPSIS:
/// ```zig
/// fn DisposeObject(ib: *IntuitionBase, object: ?*Object) void
/// ```
///
/// SINCE: 0.2. LVO -52.
///
/// INPUTS:
/// - `object` - the object, or null, which does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// `OM_DISPOSE` goes to the object's own class. Each class lets go of what
/// it had the object hold and passes it up; rootclass frees the memory.
///
/// CONTEXT:
/// - Waits: whatever its classes do.
/// - Interrupts: no; it frees memory.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The object is gone. It must be off any list it was put on first.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NewObjectTagList`
///
/// EXAMPLES:
/// ```zig
/// ib.DisposeObject(image);
/// ```
pub fn DisposeObject(ib: *IntuitionBase, object: ?*Object) void {
    var msg = Msg{ .method_id = classusr.OM_DISPOSE };
    _ = ib.iface().SendMessage(object, &msg);
}
