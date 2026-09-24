// SPDX-License-Identifier: MPL-2.0
//! NamedObjectName: the name an object was made with.

const sdk = @import("sdk");
const _namedobjects = @import("_namedobjects.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const NamedObject = sdk.utility.NamedObject;
const Object = _namedobjects.Object;

/// Returns the name of a named object.
///
/// SYNOPSIS:
/// ```zig
/// fn NamedObjectName(_: *UtilityBase, object: ?*NamedObject) ?[*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -168.
///
/// INPUTS:
/// - `object` - the object. Null gives null.
///
/// RESULT:
/// The object's name, or null for no object.
///
/// BEHAVIOR:
/// The object's own copy of the name, made by `AllocNamedObjectA`.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads only its inputs and allocates nothing.
/// - Forbid: not needed, and not taken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The name is read-only and lives as long as the
/// object.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocNamedObjectA`, `FindNamedObject`
///
/// EXAMPLES:
/// ```zig
/// const name = ub.NamedObjectName(obj).?;
/// ```
pub fn NamedObjectName(_: *UtilityBase, object: ?*NamedObject) ?[*:0]const u8 {
    return Object.of(object orelse return null).node.name;
}
