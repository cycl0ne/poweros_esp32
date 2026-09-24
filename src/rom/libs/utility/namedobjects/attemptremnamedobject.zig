// SPDX-License-Identifier: MPL-2.0
//! AttemptRemNamedObject: takes an object out of its name space only if
//! the caller's use is the only one.

const sdk = @import("sdk");
const _namedobjects = @import("_namedobjects.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const NamedObject = sdk.utility.NamedObject;

/// Takes an object out of its name space if the caller's use is the only
/// one.
///
/// SYNOPSIS:
/// ```zig
/// fn AttemptRemNamedObject(ub: *UtilityBase, object: ?*NamedObject) i32
/// ```
///
/// SINCE: 1.0. LVO -156.
///
/// INPUTS:
/// - `object` - the object to take out.
///
/// RESULT:
/// 1 if it was taken out, and the caller's use given back with it. 0 if
/// others still hold it, if it is in no name space, or for null.
///
/// BEHAVIOR:
/// The non-waiting form of `RemNamedObject`: it succeeds only where
/// `RemNamedObject` would reply at once, and otherwise changes nothing.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the name space's semaphore.
/// - Interrupts: no. It may wait.
/// - Forbid: taken here, and broken while waiting for the semaphore.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. On success the object is the caller's alone, in no
/// name space, ready for `FreeNamedObject`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemNamedObject`, `FreeNamedObject`
///
/// EXAMPLES:
/// ```zig
/// if (ub.AttemptRemNamedObject(obj) != 0) ub.FreeNamedObject(obj);
/// ```
pub fn AttemptRemNamedObject(ub: *UtilityBase, object: ?*NamedObject) i32 {
    return @intFromBool(_namedobjects.remNamedObject(ub, object, null));
}
