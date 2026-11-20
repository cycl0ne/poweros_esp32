// SPDX-License-Identifier: MIT
//! What every part of the library builds with: a document and its pool,
//! a value made in it, text copied into it, and a value placed into an
//! array or object - or taken out of one - with the list, the count and
//! the parent kept true.
//!
//! Everything a document holds is taken from its pool and nothing is
//! given back on its own: a value taken out stays in the pool until the
//! document goes, which is what lets it be placed again.

const sdk = @import("sdk");
const exec = sdk.exec;
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const Value = json.Value;
const Document = json.Document;

/// The least and the most a pool takes from the system at a time; a
/// piece of half that or more gets memory of its own.
const least_puddle: usize = 2 * 1024;
const most_puddle: usize = 64 * 1024;

/// A document with no root, its pool sized for about `expected` bytes of
/// values; null without the memory.
pub fn make(base: *JSONBase, expected: usize) ?*Document {
    const sys = base.sys_base;
    const puddle = @min(@max(expected, least_puddle), most_puddle);
    const pool = sys.CreatePool(exec.MEMF_ANY, puddle, puddle / 2) orelse return null;
    const memory = sys.AllocPooled(pool, @sizeOf(Document)) orelse {
        sys.DeletePool(pool);
        return null;
    };
    const document: *Document = @ptrCast(@alignCast(memory));
    document.* = .{ .pool = pool };
    return document;
}

/// The document and everything in it given back.
pub fn free(base: *JSONBase, document: *Document) void {
    base.sys_base.DeletePool(document.pool);
}

/// A new value of `kind`, placed nowhere: null, false, 0, an empty string,
/// an empty array or object. Null without the memory.
pub fn value(base: *JSONBase, document: *Document, kind: u32) ?*Value {
    const memory = base.sys_base.AllocPooled(document.pool, @sizeOf(Value)) orelse return null;
    const made: *Value = @ptrCast(@alignCast(memory));
    made.* = .{ .kind = kind, .document = document };
    if (kind == json.JSON_STRING) made.string = "";
    return made;
}

/// `length` bytes copied into the document's pool with a NUL after them;
/// null without the memory.
pub fn text(base: *JSONBase, document: *Document, bytes: [*]const u8, length: usize) ?[*:0]u8 {
    const into = room(base, document, length) orelse return null;
    @memcpy(into[0..length], bytes[0..length]);
    into[length] = 0;
    return into;
}

/// Room for `length` bytes and a NUL in the document's pool.
pub fn room(base: *JSONBase, document: *Document, length: usize) ?[*:0]u8 {
    const memory = base.sys_base.AllocPooled(document.pool, length + 1) orelse return null;
    const into: [*]u8 = @ptrCast(memory);
    into[length] = 0;
    return @ptrCast(into);
}

/// `item` placed into `container` before `before`, or after its last
/// value for null.
pub fn link(container: *Value, item: *Value, before: ?*Value) void {
    item.parent = container;
    if (before) |next| {
        item.next = next;
        item.prev = next.prev;
        if (next.prev) |prev| prev.next = item else container.first = item;
        next.prev = item;
    } else {
        item.next = null;
        item.prev = container.last;
        if (container.last) |last| last.next = item else container.first = item;
        container.last = item;
    }
    container.count += 1;
}

/// `item` taken out of its array or object, or off its document's root,
/// and its name dropped: placed nowhere.
pub fn unlink(item: *Value) void {
    if (item.parent) |container| {
        if (item.prev) |prev| prev.next = item.next else container.first = item.next;
        if (item.next) |next| next.prev = item.prev else container.last = item.prev;
        container.count -= 1;
    } else if (item.document.root == item) {
        item.document.root = null;
    }
    item.parent = null;
    item.next = null;
    item.prev = null;
    item.name = null;
    item.name_length = 0;
}

/// Whether `inner` is `outer` or anywhere inside it.
pub fn within(inner: *const Value, outer: *const Value) bool {
    var at: ?*const Value = inner;
    while (at) |each| : (at = each.parent) {
        if (each == outer) return true;
    }
    return false;
}

/// Whether `value` can go into `container`: an array or object (`kind`)
/// of the same document that is not inside the value itself.
pub fn placeable(container: *const Value, kind: u32, item: *const Value) bool {
    return container.kind == kind and container.document == item.document and !within(container, item);
}

/// The length of a NUL-terminated text.
pub fn lengthOf(bytes: [*:0]const u8) usize {
    var length: usize = 0;
    while (bytes[length] != 0) length += 1;
    return length;
}

/// The last value of `object` whose name is the `length` bytes at
/// `name`; null for none.
pub fn lastNamed(object: *const Value, name: [*]const u8, length: usize) ?*Value {
    var at = object.last;
    while (at) |member| : (at = member.prev) {
        if (member.name_length != length) continue;
        const own = member.name orelse continue;
        var same = true;
        for (0..length) |index| {
            if (own[index] != name[index]) {
                same = false;
                break;
            }
        }
        if (same) return member;
    }
    return null;
}
