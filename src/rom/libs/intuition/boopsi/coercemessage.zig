// SPDX-License-Identifier: MPL-2.0
//! CoerceMessage: sends a message to an object as a given class would handle it.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const Class = classes.Class;
const Object = classes.Object;
const Msg = classusr.Msg;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Sends a message to an object as a given class would handle it.
///
/// SYNOPSIS:
/// ```zig
/// fn CoerceMessage(ib: *IntuitionBase, cl: *Class, object: ?*Object,
///     msg: *Msg) usize
/// ```
///
/// SINCE: 0.2. LVO -76.
///
/// INPUTS:
/// - `cl` - the class whose dispatcher is to handle it.
/// - `object` - the object, which is handed to that dispatcher as it is.
/// - `msg` - the message.
///
/// RESULT:
/// What that class answers.
///
/// BEHAVIOR:
/// The class's dispatcher is called through utility.library's
/// CallHookPkt, with the class as the hook. Every message to every object
/// ends here.
///
/// CONTEXT:
/// - Waits: whatever the class does.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The message is the caller's.
///
/// NOTES:
/// - The one place every message passes through, and a slot - so one
///   SetFunction sees them all.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SendMessage`, `SendSuperMessage`
///
/// EXAMPLES:
/// ```zig
/// const made = ib.CoerceMessage(cl, @ptrCast(cl), @ptrCast(&new_msg));
/// ```
pub fn CoerceMessage(ib: *IntuitionBase, cl: *Class, object: ?*Object, msg: *Msg) usize {
    // No object, no method: every message is about one. The classes here
    // all check for themselves, but a class from anywhere else is written
    // to the contract that it is never handed nothing.
    const o = object orelse return 0;
    return ib.utility_base.CallHookPkt(&cl.dispatcher, o, msg);
}
