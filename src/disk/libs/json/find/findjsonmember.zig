// SPDX-License-Identifier: MIT
//! FindJSONMember: an object's member by its name.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const _document = @import("../document/_document.zig");

/// Finds the member of an object called `name`.
///
/// SYNOPSIS:
/// ```zig
/// fn FindJSONMember(base: *JSONBase, object: ?*const json.Value, name: [*:0]const u8) ?*json.Value
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `object`: the object; null, or a value that is not an object,
///   finds nothing.
/// - `name`: the member's name, UTF-8, as the text has it with its
///   escapes undone.
///
/// RESULT:
/// The member; null for none.
///
/// BEHAVIOR:
/// Names are compared byte for byte, capitals and all. When the object
/// names a member twice, the last of them is found, as a later member
/// stands for an earlier one of the same name. The members are gone
/// through from the last back.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself; nothing is allocated.
/// - Locks: none taken; the caller keeps other tasks off the document.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The member is the document's.
///
/// BUGS:
/// A name with a NUL in it - a `\u0000` - cannot be asked for here; go
/// through the members' `name` and `name_length` instead.
///
/// SEE ALSO:
/// `FindJSONPointer`, `GetJSONItem`, `SetJSONMember`
///
/// EXAMPLES:
/// ```zig
/// const current = jb.FindJSONMember(document.root, "current");
/// var celsius: f64 = 0;
/// _ = jb.GetJSONNumber(jb.FindJSONMember(current, "temperature_2m"), &celsius);
/// ```
pub fn FindJSONMember(_: *JSONBase, object: ?*const json.Value, name: [*:0]const u8) ?*json.Value {
    const container = object orelse return null;
    if (container.kind != json.JSON_OBJECT) return null;
    return _document.lastNamed(container, name, _document.lengthOf(name));
}
