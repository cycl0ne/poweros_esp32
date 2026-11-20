// SPDX-License-Identifier: MIT
//! CopyJSONValue: a value and all it holds copied, into the same document
//! or another.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const _document = @import("../document/_document.zig");

/// Copies a value and everything in it.
///
/// SYNOPSIS:
/// ```zig
/// fn CopyJSONValue(base: *JSONBase, document: *json.Document, value: *const json.Value) ?*json.Value
/// ```
///
/// SINCE: 1.0. LVO -88.
///
/// INPUTS:
/// - `document`: the document to make the copy in: the value's own or
///   another.
/// - `value`: what to copy.
///
/// RESULT:
/// The copy, placed nowhere; null without the memory.
///
/// BEHAVIOR:
/// Every value inside is copied too, in its order, with its name, text,
/// number and truth; the copy is the value's alone, so a change to one
/// leaves the other as it is. The value's own name is not copied: the
/// copy is placed nowhere. The tree is walked without recursion.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not from an interrupt.
/// - Locks: none taken; the caller keeps other tasks off both documents.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The copy is `document`'s, given back with it. When the memory runs out
/// halfway, what was copied stays in `document` until it goes.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetJSONMember`, `InsertJSONItem`, `SetJSONRoot`
///
/// EXAMPLES:
/// ```zig
/// // A place of the answer kept in the settings, which outlive it.
/// const kept = jb.CopyJSONValue(settings, found) orelse return;
/// _ = jb.InsertJSONItem(places, kept, json.JSON_END);
/// ```
pub fn CopyJSONValue(base: *JSONBase, document: *json.Document, value: *const json.Value) ?*json.Value {
    const top = one(base, document, value) orelse return null;
    var from = value.first orelse return top;
    var into = top;
    while (true) {
        const made = one(base, document, from) orelse return null;
        if (from.name) |name| {
            made.name = _document.text(base, document, name, from.name_length) orelse return null;
            made.name_length = from.name_length;
        }
        _document.link(into, made, null);
        if (from.first) |inner| {
            into = made;
            from = inner;
            continue;
        }
        // On to the next value: after this one, or after the container
        // each one ends.
        while (from.next == null) {
            const up = from.parent.?;
            if (up == value) return top;
            from = up;
            into = into.parent.?;
        }
        from = from.next.?;
    }
}

/// One value's own content copied, without what it holds.
fn one(base: *JSONBase, document: *json.Document, from: *const json.Value) ?*json.Value {
    const made = _document.value(base, document, from.kind) orelse return null;
    made.flags = from.flags;
    made.truth = from.truth;
    made.number = from.number;
    made.integer = from.integer;
    if (from.kind == json.JSON_STRING) {
        made.string = _document.text(base, document, from.string orelse "", from.length) orelse return null;
        made.length = from.length;
    }
    return made;
}
