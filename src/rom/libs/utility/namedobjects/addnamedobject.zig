// SPDX-License-Identifier: MPL-2.0
//! AddNamedObject: puts an object into a name space by priority, refusing
//! a duplicate name where the name space says NSF_NODUPS.

const sdk = @import("sdk");
const _namedobjects = @import("_namedobjects.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const NamedObject = sdk.utility.NamedObject;
const NSF_NODUPS = sdk.utility.NSF_NODUPS;
const Object = _namedobjects.Object;

/// Puts an object into a name space.
///
/// SYNOPSIS:
/// ```zig
/// fn AddNamedObject(ub: *UtilityBase, name_space: ?*NamedObject, object: ?*NamedObject) bool
/// ```
///
/// SINCE: 1.0. LVO -148.
///
/// INPUTS:
/// - `name_space` - an object made with `ANO_NameSpace`, or null for the
///   system's root name space.
/// - `object` - the object to add. In no name space yet.
///
/// RESULT:
/// True if it was added. False if `name_space` has no name space, the
/// object is null, already in a name space or would go into its own, or the
/// name space has `NSF_NODUPS` and the name is taken.
///
/// BEHAVIOR:
/// The object goes in by priority, behind those of the same priority. The
/// name space's semaphore is held exclusively meanwhile, so no search sees
/// it half in.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the name space's semaphore.
/// - Interrupts: no. It may wait.
/// - Forbid: must not be relied on across it: waiting for the semaphore
///   breaks it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The name space holds the object until
/// `RemNamedObject` or `AttemptRemNamedObject` takes it out; the caller
/// keeps its use.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindNamedObject`, `RemNamedObject`, `AllocNamedObjectA`
///
/// EXAMPLES:
/// ```zig
/// if (!ub.AddNamedObject(null, obj)) {
///     ub.FreeNamedObject(obj);
///     return error.Exists;
/// }
/// ```
pub fn AddNamedObject(ub: *UtilityBase, name_space: ?*NamedObject, object: ?*NamedObject) bool {
    const space = _namedobjects.spaceOf(ub, name_space) orelse return false;
    const obj = Object.of(object orelse return false);
    if (obj.parent != null or obj.space == space) return false;
    ub.sys_base.ObtainSemaphore(&space.lock);
    defer ub.sys_base.ReleaseSemaphore(&space.lock);
    if (space.flags & NSF_NODUPS != 0 and _namedobjects.search(ub, space, space.entries.head.?, obj.node.name.?) != null) return false;
    ub.sys_base.Enqueue(&space.entries, &obj.node);
    obj.parent = space;
    return true;
}
