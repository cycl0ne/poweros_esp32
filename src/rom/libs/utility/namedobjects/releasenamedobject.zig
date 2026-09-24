// SPDX-License-Identifier: MPL-2.0
//! ReleaseNamedObject: gives back one use of an object; the last one
//! replies a pending RemNamedObject's message.

const sdk = @import("sdk");
const _namedobjects = @import("_namedobjects.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const NamedObject = sdk.utility.NamedObject;
const Object = _namedobjects.Object;

/// Gives back one use of an object.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseNamedObject(ub: *UtilityBase, object: ?*NamedObject) void
/// ```
///
/// SINCE: 1.0. LVO -172.
///
/// INPUTS:
/// - `object` - the object. Null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The use count goes down under Forbid. When it reaches zero and a
/// `RemNamedObject` is waiting, its message is replied now. A count already
/// at zero stays there.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The caller's use is gone.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindNamedObject`, `RemNamedObject`
///
/// EXAMPLES:
/// ```zig
/// ub.ReleaseNamedObject(obj);
/// ```
pub fn ReleaseNamedObject(ub: *UtilityBase, object: ?*NamedObject) void {
    const obj = Object.of(object orelse return);
    ub.sys_base.Forbid();
    defer ub.sys_base.Permit();
    if (obj.use_count == 0) return;
    obj.use_count -= 1;
    if (obj.use_count != 0) return;
    const msg = obj.remove_msg orelse return;
    obj.remove_msg = null;
    ub.sys_base.ReplyMsg(msg);
}
