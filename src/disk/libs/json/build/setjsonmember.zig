// SPDX-License-Identifier: MIT
//! SetJSONMember: a value made an object's member, in place of one of its
//! name.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const _document = @import("../document/_document.zig");

/// Makes a value the member `name` of an object.
///
/// SYNOPSIS:
/// ```zig
/// fn SetJSONMember(base: *JSONBase, object: *json.Value, name: [*:0]const u8, value: *json.Value) bool
/// ```
///
/// SINCE: 1.0. LVO -92.
///
/// INPUTS:
/// - `object`: the object.
/// - `name`: the member's name, UTF-8; copied.
/// - `value`: the value, made in the object's document.
///
/// RESULT:
/// True; false, and nothing changed, when `object` is no object, the
/// value is another document's, the object is inside the value - which
/// would hold itself - or there is no memory for the name.
///
/// BEHAVIOR:
/// A value placed elsewhere - in an array, an object, or as the root - is
/// taken out of there first. When the object has a member of that name,
/// the value takes its place in the order and the old one is placed
/// nowhere, and so is any other member of the name; otherwise the value
/// goes after the last member.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not from an interrupt.
/// - Locks: none taken; the caller keeps other tasks off the document.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The values stay the document's. One that was replaced can be placed
/// again; it is given back with the document.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindJSONMember`, `RemoveJSONValue`, `InsertJSONItem`
///
/// EXAMPLES:
/// ```zig
/// const latitude = jb.CreateJSONNumber(document, 52.52) orelse return;
/// if (!jb.SetJSONMember(place, "latitude", latitude)) return;
/// ```
pub fn SetJSONMember(base: *JSONBase, object: *json.Value, name: [*:0]const u8, value: *json.Value) bool {
    if (!_document.placeable(object, json.JSON_OBJECT, value)) return false;
    const length = _document.lengthOf(name);
    const copy = _document.text(base, object.document, name, length) orelse return false;
    _document.unlink(value);
    const replaced = _document.lastNamed(object, name, length);
    _document.link(object, value, replaced);
    value.name = copy;
    value.name_length = @intCast(length);
    if (replaced == null) return true;
    // Every other member of the name goes: the one replaced and any
    // before it.
    var at = object.first;
    while (at) |member| {
        at = member.next;
        if (member == value) continue;
        if (member.name_length == length and same(member.name.?, name, length)) _document.unlink(member);
    }
    return true;
}

fn same(one: [*:0]const u8, other: [*:0]const u8, length: usize) bool {
    for (0..length) |at| {
        if (one[at] != other[at]) return false;
    }
    return true;
}
