// SPDX-License-Identifier: MPL-2.0
//! FindNamedObject: the next object of a name space with a given name,
//! with one more use for the caller.

const sdk = @import("sdk");
const _namedobjects = @import("_namedobjects.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const NamedObject = sdk.utility.NamedObject;
const Object = _namedobjects.Object;

/// Finds the next object of a name space with a given name.
///
/// SYNOPSIS:
/// ```zig
/// fn FindNamedObject(ub: *UtilityBase, name_space: ?*NamedObject, name: ?[*:0]const u8, last_object: ?*NamedObject) ?*NamedObject
/// ```
///
/// SINCE: 1.0. LVO -160.
///
/// INPUTS:
/// - `name_space` - an object with a name space, or null for the root name
///   space.
/// - `name` - the name; null matches every object.
/// - `last_object` - where the previous search ended, to go on from there;
///   null to start at the beginning. Still held, and still in this name
///   space.
///
/// RESULT:
/// The object, with one more use for the caller, or null.
///
/// BEHAVIOR:
/// Names compare without case unless the name space has `NSF_CASE`. With a
/// null name, going on from each result visits the whole name space by
/// priority. The semaphore is held shared, so any number of searches run at
/// once; the use count is raised under Forbid, since the others holding the
/// semaphore may raise it too.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the name space's semaphore
///   exclusively.
/// - Interrupts: no. It may wait.
/// - Forbid: must not be relied on across it: waiting for the semaphore
///   breaks it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The caller holds a use of the object and gives it
/// back with `ReleaseNamedObject`; until then a `RemNamedObject` waits for
/// it.
///
/// NOTES:
/// `last_object` must still be in the name space: one taken out since has
/// no place in it to go on from.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleaseNamedObject`, `AddNamedObject`
///
/// EXAMPLES:
/// ```zig
/// var obj = ub.FindNamedObject(space, null, null);
/// while (obj) |current| {
///     use(current);
///     obj = ub.FindNamedObject(space, null, current);
///     ub.ReleaseNamedObject(current);
/// }
/// ```
pub fn FindNamedObject(ub: *UtilityBase, name_space: ?*NamedObject, name: ?[*:0]const u8, last_object: ?*NamedObject) ?*NamedObject {
    const space = _namedobjects.spaceOf(ub, name_space) orelse return null;
    ub.sys_base.ObtainSemaphoreShared(&space.lock);
    defer ub.sys_base.ReleaseSemaphore(&space.lock);
    const start = if (last_object) |last| Object.of(last).node.succ.? else space.entries.head.?;
    const found = _namedobjects.search(ub, space, start, name) orelse return null;
    // Other finders hold the semaphore too, and a load and a store are not
    // atomic.
    ub.sys_base.Forbid();
    found.use_count += 1;
    ub.sys_base.Permit();
    return &found.public;
}
