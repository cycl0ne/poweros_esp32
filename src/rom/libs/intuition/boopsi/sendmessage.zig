// SPDX-License-Identifier: MPL-2.0
//! SendMessage: sends a message to an object.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const Object = classes.Object;
const Msg = classusr.Msg;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Sends a message to an object.
///
/// SYNOPSIS:
/// ```zig
/// fn SendMessage(ib: *IntuitionBase, object: ?*Object, msg: *Msg) usize
/// ```
///
/// SINCE: 0.2. LVO -68.
///
/// INPUTS:
/// - `object` - the object, or null, which answers 0.
/// - `msg` - the message: a method ID, then that method's fields.
///
/// RESULT:
/// Whatever the object's class answers, as the method defines it.
///
/// BEHAVIOR:
/// The message goes to the dispatcher of the class the object was made
/// of, which passes on to its superclass what it does not handle.
///
/// CONTEXT:
/// - Waits: whatever the class does.
/// - Interrupts: no, unless a class says a method is safe there.
/// - Forbid: not needed.
/// - Process: a Task will do, unless a class says otherwise.
///
/// OWNERSHIP:
/// The message is the caller's; a class does not keep it.
///
/// NOTES:
/// - This is how any method is invoked: `NewObjectTagList`,
///   `DisposeObject`, `SetAttrsTagList` and `GetAttr` are this with their
///   message made for the caller.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SendSuperMessage`, `CoerceMessage`
///
/// EXAMPLES:
/// ```zig
/// var draw = imageclass.ImpDraw{ .method_id = IM_DRAW, .rast_port = rp };
/// _ = ib.SendMessage(image, @ptrCast(&draw));
/// ```
pub fn SendMessage(ib: *IntuitionBase, object: ?*Object, msg: *Msg) usize {
    const o = object orelse return 0;
    return ib.iface().CoerceMessage(classes.objectClass(o), o, msg);
}
