// SPDX-License-Identifier: MIT
//! FindJSONPointer: the value a JSON Pointer (RFC 6901) names.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;

/// Finds the value a JSON Pointer names.
///
/// SYNOPSIS:
/// ```zig
/// fn FindJSONPointer(base: *JSONBase, from: ?*const json.Value, pointer: [*:0]const u8) ?*json.Value
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `from`: where the pointer starts, a document's root or any value
///   in it; null finds nothing.
/// - `pointer`: the pointer: empty for `from` itself, or a `/` before
///   each step - an object's member by its name, `~1` for a `/` in it and
///   `~0` for a `~`, or an array's item by its place, from 0.
///
/// RESULT:
/// The value; null when a step finds nothing, or the pointer is not one.
///
/// BEHAVIOR:
/// Each step goes one level down. A member is found as `FindJSONMember`
/// finds one, the last of a name; an item's place is written in digits
/// with no leading zero. `-`, the place after an array's last item,
/// names no value and finds nothing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself; nothing is allocated.
/// - Locks: none taken; the caller keeps other tasks off the document.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The value is the document's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindJSONMember`, `GetJSONItem`
///
/// EXAMPLES:
/// ```zig
/// var high: f64 = 0;
/// if (jb.GetJSONNumber(jb.FindJSONPointer(document.root, "/daily/temperature_2m_max/1"), &high)) {
///     // tomorrow's highest
/// }
/// ```
pub fn FindJSONPointer(_: *JSONBase, from: ?*const json.Value, pointer: [*:0]const u8) ?*json.Value {
    var at: *const json.Value = from orelse return null;
    var place: usize = 0;
    if (pointer[0] != 0 and pointer[0] != '/') return null;
    while (pointer[place] == '/') {
        place += 1;
        const start = place;
        while (pointer[place] != 0 and pointer[place] != '/') place += 1;
        const step = pointer[start..place];
        at = switch (at.kind) {
            json.JSON_OBJECT => member(at, step) orelse return null,
            json.JSON_ARRAY => item(at, step) orelse return null,
            else => return null,
        };
    }
    return @constCast(at);
}

/// The last member of `object` whose name the step is, its `~0` and
/// `~1` read as `~` and `/`.
fn member(object: *const json.Value, step: []const u8) ?*json.Value {
    var at = object.last;
    while (at) |each| : (at = each.prev) {
        if (named(each, step)) return each;
    }
    return null;
}

fn named(each: *const json.Value, step: []const u8) bool {
    const name = each.name orelse return false;
    var read: usize = 0;
    var compared: usize = 0;
    while (read < step.len) : (compared += 1) {
        var char = step[read];
        read += 1;
        if (char == '~') {
            if (read >= step.len) return false;
            char = switch (step[read]) {
                '0' => '~',
                '1' => '/',
                else => return false,
            };
            read += 1;
        }
        if (compared >= each.name_length or name[compared] != char) return false;
    }
    return compared == each.name_length;
}

/// The array's item at the place the step writes: digits, no leading
/// zero.
fn item(array: *const json.Value, step: []const u8) ?*json.Value {
    if (step.len == 0 or (step.len > 1 and step[0] == '0')) return null;
    var index: u64 = 0;
    for (step) |char| {
        if (char < '0' or char > '9') return null;
        index = index * 10 + (char - '0');
        if (index >= array.count) return null;
    }
    var at = array.first;
    var left = index;
    while (left > 0) : (left -= 1) at = at.?.next;
    return at;
}
