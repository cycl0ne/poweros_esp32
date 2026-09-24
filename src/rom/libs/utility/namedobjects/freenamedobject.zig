// SPDX-License-Identifier: MPL-2.0
//! FreeNamedObject: gives back an object that is in no name space.

const sdk = @import("sdk");
const _namedobjects = @import("_namedobjects.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const NamedObject = sdk.utility.NamedObject;
const Object = _namedobjects.Object;

/// Gives back the memory of a named object.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeNamedObject(ub: *UtilityBase, object: ?*NamedObject) void
/// ```
///
/// SINCE: 1.0. LVO -164.
///
/// INPUTS:
/// - `object` - the object. Null does nothing. In no name space, and with
///   its own name space empty.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// An object still in a name space is not freed at all, and neither is one
/// whose own name space still holds objects: the mistake leaks the object
/// rather than leaving a freed node on a list others search, or objects on
/// a list in freed memory.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the object's own name space.
/// - Interrupts: no. `FreeMem` takes Forbid.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The object, its name and its user space are gone.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocNamedObjectA`, `RemNamedObject`, `AttemptRemNamedObject`
///
/// EXAMPLES:
/// ```zig
/// ub.FreeNamedObject(obj);
/// ```
pub fn FreeNamedObject(ub: *UtilityBase, object: ?*NamedObject) void {
    const obj = Object.of(object orelse return);
    if (obj.parent != null) return;
    if (obj.space) |space| {
        // Objects still in it would be left on a list in freed memory.
        const sys = ub.sys_base;
        sys.ObtainSemaphoreShared(&space.lock);
        const holds = space.entries.first() != null;
        sys.ReleaseSemaphore(&space.lock);
        if (holds) return;
    }
    ub.sys_base.FreeVec(obj);
}
