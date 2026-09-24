// SPDX-License-Identifier: MPL-2.0
//! SendSuperMessage: sends a message on to a class's superclass.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const Class = classes.Class;
const Object = classes.Object;
const Msg = classusr.Msg;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Sends a message on to a class's superclass.
///
/// SYNOPSIS:
/// ```zig
/// fn SendSuperMessage(ib: *IntuitionBase, cl: *Class, object: ?*Object,
///     msg: *Msg) usize
/// ```
///
/// SINCE: 0.2. LVO -72.
///
/// INPUTS:
/// - `cl` - the class whose dispatcher is running: the one passed to it.
/// - `object` - the object, as the dispatcher was given it.
/// - `msg` - the message.
///
/// RESULT:
/// What the superclass answers; 0 when `cl` has none.
///
/// BEHAVIOR:
/// The superclass handles it as if the object were one of its own. This is
/// how a dispatcher passes on a message it does not handle, and how it
/// lets the classes above it do their part first.
///
/// CONTEXT:
/// - Waits: whatever the superclass does.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The message is the caller's.
///
/// NOTES:
/// - Pass the class the dispatcher was given, never the object's own:
///   that would send the message back down to where it started.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SendMessage`, `CoerceMessage`
///
/// EXAMPLES:
/// ```zig
/// else => return ib.SendSuperMessage(cl, object, msg),
/// ```
pub fn SendSuperMessage(ib: *IntuitionBase, cl: *Class, object: ?*Object, msg: *Msg) usize {
    const super = cl.super orelse return 0;
    return ib.iface().CoerceMessage(super, object, msg);
}
