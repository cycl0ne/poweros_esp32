// SPDX-License-Identifier: MPL-2.0
//! The namespace: a tree of names of four characters each, `\` at its
//! root, and the object each name holds.
//!
//! **Nodes.** A node is one name: its four characters, its parent, its
//! children in the order they were defined, and the object it holds (null
//! for a scope with nothing of its own, as `\_GPE`). Every node also says
//! which table defined it - its place in the order the tables were
//! loaded, from 1 - and 0 for the names the namespace starts with.
//!
//! **What the namespace starts with.** The scopes the specification
//! names at the root - `\_GPE` for the general events, `\_PR` for old
//! processor objects, `\_SB` for the devices on the system bus, `\_SI`
//! for the system indicators, `\_TZ` for old thermal zones; `\_SB` and
//! `\_TZ` are devices, as ObjectType answers for them on the machines the
//! firmware was tested on - and four objects of the interpreter's:
//! `\_REV` (2), `\_OS` ("Microsoft Windows NT"), `\_GL`, the mutex that
//! stands for the firmware's global lock, and `\_OSI`, the method that
//! tells the firmware which interfaces this system has. They are made in
//! that order, before any table is loaded.
//!
//! **Paths.** A path is a run of names, from the root where it starts
//! with `\`, from as many parents up as it has `^` in front, and from the
//! scope it is used in otherwise. The bytecode writes one as a NameString
//! (`Path`, read in place); a caller writes one as text - "\\_SB.PCI0",
//! "PCI0._HID", "^_PRT", a name shorter than four characters filled with
//! `_` (`parseText`).
//!
//! **Finding a name** (`find`): every name of the path must be there,
//! each looked for among the children of the one before, and another
//! name for a node (Alias) stands for that node. A single name with
//! neither `\` nor `^` in front is, where the bytecode refers to it
//! (`.search`), looked for in the scope it is used in and then in each
//! scope above, up to the root - the specification's search rules; a
//! caller's path (`.exact`), and a name being defined, never search.

const sdk = @import("sdk");
const exec = sdk.exec;
const machine = @import("../machine/_machine.zig");
const AcpiBase = @import("../acpi_base.zig").AcpiBase;
const object = @import("../object/_object.zig");
const Object = object.Object;

pub const Node = struct {
    /// The name's four characters, the first in the lowest byte, as the
    /// bytecode writes them.
    name: u32,
    parent: ?*Node = null,
    /// The first and the last child, and the next of the parent's.
    first: ?*Node = null,
    last: ?*Node = null,
    next: ?*Node = null,
    /// What the name holds: one reference to it, the node's.
    object: ?*Object = null,
    /// The table that defined it, from 1 in the order they were loaded;
    /// 0 for the names the namespace starts with.
    table: u16 = 0,

    /// The object's kind, `.uninitialized` where it holds none.
    pub fn kind(node: *const Node) object.Kind {
        const held = node.object orelse return .uninitialized;
        return held.kind();
    }
};

/// The four characters of `text` (one to four of them; the rest `_`) as
/// a node's name.
pub fn nameOf(text: []const u8) u32 {
    var bytes: [4]u8 = @splat('_');
    for (text[0..@min(text.len, 4)], 0..) |char, index| bytes[index] = char;
    return segmentAt(&bytes);
}

/// The name whose four characters are at `bytes`.
pub fn segmentAt(bytes: [*]const u8) u32 {
    return @as(u32, bytes[0]) | @as(u32, bytes[1]) << 8 | @as(u32, bytes[2]) << 16 | @as(u32, bytes[3]) << 24;
}

/// A name's four characters.
pub fn textOf(name: u32) [4]u8 {
    return .{ @truncate(name), @truncate(name >> 8), @truncate(name >> 16), @truncate(name >> 24) };
}

/// Whether `char` may start a name, and whether it may follow.
pub fn isLead(char: u8) bool {
    return (char >= 'A' and char <= 'Z') or char == '_';
}

pub fn isNameChar(char: u8) bool {
    return isLead(char) or (char >= '0' and char <= '9');
}

/// A path: from the root, or from `parents` scopes above the one it is
/// used in; then `count` names of four characters at `segments`.
pub const Path = struct {
    root: bool = false,
    parents: u8 = 0,
    count: u8 = 0,
    segments: [*]const u8 = undefined,

    pub fn segment(path: Path, index: u8) u32 {
        return segmentAt(path.segments + @as(usize, index) * 4);
    }

    /// Whether the search rules apply to it: one name, and nothing in
    /// front of it.
    pub fn searched(path: Path) bool {
        return !path.root and path.parents == 0 and path.count == 1;
    }
};

/// The most names a caller's path may have.
pub const MOST_SEGMENTS = 32;

/// A caller's path read into names: what `parseText` fills.
pub const TextPath = struct {
    path: Path = .{},
    bytes: [MOST_SEGMENTS * 4]u8 = undefined,
};

/// `text`, a path as a caller writes it, into `into`: false where it is
/// not one - a name longer than four characters or with a character a
/// name may not have, an empty name between two dots, more than
/// MOST_SEGMENTS names. Lower-case letters are taken as upper-case ones;
/// "\\" alone is the root.
pub fn parseText(text: [*:0]const u8, into: *TextPath) bool {
    into.* = .{};
    var at: usize = 0;
    if (text[0] == '\\') {
        into.path.root = true;
        at = 1;
    } else while (text[at] == '^') : (at += 1) {
        if (into.path.parents == 255) return false;
        into.path.parents += 1;
    }
    into.path.segments = &into.bytes;
    if (text[at] == 0) return true;
    while (true) {
        if (into.path.count == MOST_SEGMENTS) return false;
        const base = @as(usize, into.path.count) * 4;
        var length: usize = 0;
        while (text[at] != 0 and text[at] != '.') : (at += 1) {
            if (length == 4) return false;
            var char = text[at];
            if (char >= 'a' and char <= 'z') char -= 'a' - 'A';
            if (!(if (length == 0) isLead(char) else isNameChar(char))) return false;
            into.bytes[base + length] = char;
            length += 1;
        }
        if (length == 0) return false;
        while (length < 4) : (length += 1) into.bytes[base + length] = '_';
        into.path.count += 1;
        if (text[at] == 0) return true;
        at += 1;
    }
}

/// The child of `scope` named `name`, the node itself where it is
/// another name for one.
pub fn child(scope: *const Node, name: u32) ?*Node {
    var at = scope.first;
    while (at) |node| : (at = node.next) {
        if (node.name == name) return node;
    }
    return null;
}

/// The node another name stands for: `node` itself where it is no alias.
pub fn target(node: *Node) *Node {
    var at = node;
    var hops: u32 = 0;
    while (at.object) |held| {
        switch (held.value) {
            .alias => |aliased| at = aliased,
            else => break,
        }
        hops += 1;
        if (hops == 16) break; // an alias of an alias of ... - the bytecode is broken
    }
    return at;
}

/// How a name is looked for: as written, or by the search rules where it
/// is a single name.
pub const Rule = enum { exact, search };

/// The node `path` names from `scope`, an alias standing for its node;
/// null where there is none.
pub fn find(ab: *const AcpiBase, scope: *Node, path: Path, rule: Rule) ?*Node {
    if (rule == .search and path.searched()) {
        const name = path.segment(0);
        var at: ?*Node = scope;
        while (at) |node| : (at = node.parent) {
            if (child(node, name)) |found| return target(found);
        }
        return null;
    }
    const start = startOf(ab, scope, path) orelse return null;
    var at = start;
    var index: u8 = 0;
    while (index < path.count) : (index += 1) {
        at = target(child(at, path.segment(index)) orelse return null);
    }
    return at;
}

/// Where `path` starts from `scope`: the root, or the scope `parents`
/// above it; null where that is above the root.
fn startOf(ab: *const AcpiBase, scope: *Node, path: Path) ?*Node {
    if (path.root) return ab.root;
    var at = scope;
    var up: u8 = 0;
    while (up < path.parents) : (up += 1) at = at.parent orelse return null;
    return at;
}

/// What `create` found.
pub const Made = union(enum) {
    /// The name was not there, and is now: the node, holding nothing yet.
    made: *Node,
    /// The name was there already: that node.
    there: *Node,
    /// A name of the path in front of the last is not there, or the path
    /// has no names; or there was no memory.
    missing,
    no_memory,
};

/// The last name of `path`, made in the scope the rest of it names from
/// `scope`, as defined by table `table`: the new node, added after its
/// parent's other children. A name that is there already is answered as
/// it is, never made again.
pub fn create(ab: *AcpiBase, scope: *Node, path: Path, table: u16) Made {
    if (path.count == 0) return .missing;
    const start = startOf(ab, scope, path) orelse return .missing;
    var parent = start;
    var index: u8 = 0;
    while (index + 1 < path.count) : (index += 1) {
        parent = target(child(parent, path.segment(index)) orelse return .missing);
    }
    const name = path.segment(path.count - 1);
    if (child(parent, name)) |there| return .{ .there = there };
    const node = machine.alloc(ab, Node) orelse return .no_memory;
    node.* = .{ .name = name, .table = table };
    adopt(parent, node);
    return .{ .made = node };
}

/// `node` as `parent`'s last child.
fn adopt(parent: *Node, node: *Node) void {
    node.parent = parent;
    node.next = null;
    if (parent.last) |last| last.next = node else parent.first = node;
    parent.last = node;
}

/// The node after `node` in the namespace's order - itself, its children
/// in turn, then its next sibling - within the tree below `top`; null
/// after the last.
pub fn next(top: *const Node, node: *Node) ?*Node {
    if (node.first) |first| return first;
    var at = node;
    while (at != top) {
        if (at.next) |sibling| return sibling;
        at = at.parent orelse return null;
    }
    return null;
}

/// How deep `node` is: 0 for the root's children.
pub fn depthOf(node: *const Node) u32 {
    var depth: u32 = 0;
    var at = node.parent;
    while (at) |parent| : (at = parent.parent) {
        if (parent.parent == null) break;
        depth += 1;
    }
    return depth;
}

/// `node`'s path from the root into `into`, NUL-terminated - "\\_SB.PCI0",
/// each name without the `_` that fill it out, "\\" for the root - cut
/// where `into` is too short. Returns its length.
pub fn pathOf(node: *const Node, into: []u8) usize {
    if (into.len == 0) return 0;
    var names: [MOST_DEPTH]u32 = undefined;
    var count: usize = 0;
    var at: ?*const Node = node;
    while (at) |each| : (at = each.parent) {
        if (each.parent == null) break;
        if (count == MOST_DEPTH) break;
        names[count] = each.name;
        count += 1;
    }
    var length: usize = 0;
    put(into, &length, '\\');
    while (count > 0) {
        count -= 1;
        const text = textOf(names[count]);
        var shown: usize = 4;
        while (shown > 1 and text[shown - 1] == '_') shown -= 1;
        for (text[0..shown]) |char| put(into, &length, char);
        if (count > 0) put(into, &length, '.');
    }
    into[@min(length, into.len - 1)] = 0;
    return @min(length, into.len - 1);
}

/// The deepest a path is shown to.
const MOST_DEPTH = 64;

fn put(into: []u8, length: *usize, char: u8) void {
    if (length.* + 1 < into.len) into[length.*] = char;
    length.* += 1;
}

/// One of the names the namespace starts with: what it holds, a string's
/// text where it holds one, nothing for a scope.
const Start = struct {
    name: *const [4]u8,
    value: object.Value = .{ .uninitialized = {} },
    text: ?[]const u8 = null,
};

/// The root and the names the namespace starts with. False without
/// memory, and nothing made then.
pub fn make(ab: *AcpiBase) bool {
    const root = machine.alloc(ab, Node) orelse return false;
    root.* = .{ .name = segmentAt("\\___") };
    ab.root = root;
    const starts = [_]Start{
        .{ .name = "_GPE" },
        .{ .name = "_PR_" },
        .{ .name = "_SB_", .value = .{ .device = {} } },
        .{ .name = "_SI_" },
        .{ .name = "_TZ_", .value = .{ .device = {} } },
        .{ .name = "_REV", .value = .{ .integer = 2 } },
        .{ .name = "_OS_", .text = "Microsoft Windows NT" },
        .{ .name = "_GL_", .value = .{ .mutex = .{} } },
        .{ .name = "_OSI", .value = .{ .method = .{ .flags = 1, .builtin = .osi } } },
    };
    for (starts) |start| {
        const node = machine.alloc(ab, Node) orelse return failed(ab);
        node.* = .{ .name = segmentAt(start.name) };
        adopt(root, node);
        node.object = if (start.text) |text|
            object.makeString(ab, text) orelse return failed(ab)
        else switch (start.value) {
            .uninitialized => continue,
            else => object.make(ab, start.value) orelse return failed(ab),
        };
    }
    return true;
}

fn failed(ab: *AcpiBase) bool {
    discard(ab);
    return false;
}

/// The whole namespace freed: every node and what each holds. The base
/// has no namespace afterwards.
pub fn discard(ab: *AcpiBase) void {
    const root = ab.root orelse return;
    var at: ?*Node = root;
    // Down to the first leaf, then each leaf freed and its parent's next
    // child gone down to, until the root is a leaf itself.
    while (at) |node| {
        if (node.first) |first| {
            at = first;
            continue;
        }
        const parent = node.parent;
        if (parent) |above| {
            above.first = node.next;
            if (above.first == null) above.last = null;
        }
        object.release(ab, node.object);
        machine.free(ab, Node, node);
        at = parent;
    }
    ab.root = null;
}

// --- tests ------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;
const testmachine = @import("../tests/machine.zig");

test "a caller's path is read into its names" {
    var path: TextPath = undefined;
    try testing.expect(parseText("\\_SB.PCI0", &path));
    try testing.expect(path.path.root);
    try testing.expectEqual(@as(u8, 2), path.path.count);
    try testing.expectEqual(nameOf("_SB"), path.path.segment(0));
    try testing.expectEqual(nameOf("PCI0"), path.path.segment(1));
    try testing.expect(parseText("^^_prt", &path));
    try testing.expectEqual(@as(u8, 2), path.path.parents);
    try testing.expectEqual(nameOf("_PRT"), path.path.segment(0));
    try testing.expect(parseText("\\", &path));
    try testing.expectEqual(@as(u8, 0), path.path.count);
    try testing.expect(!parseText("\\_SB.TOOLONG", &path));
    try testing.expect(!parseText("\\_SB..PCI0", &path));
    try testing.expect(!parseText("\\1BAD", &path));
    try testing.expect(!parseText("\\_SB.", &path));
}

test "the namespace starts with its scopes and the interpreter's objects, in order" {
    var test_machine: testmachine.TestMachine = .{};
    const ab = test_machine.base();
    try testing.expect(make(ab));
    defer discard(ab);
    const root = ab.root.?;
    const want = [_]struct { name: []const u8, kind: object.Kind }{
        .{ .name = "_GPE", .kind = .uninitialized }, .{ .name = "_PR_", .kind = .uninitialized },
        .{ .name = "_SB_", .kind = .device },        .{ .name = "_SI_", .kind = .uninitialized },
        .{ .name = "_TZ_", .kind = .device },        .{ .name = "_REV", .kind = .integer },
        .{ .name = "_OS_", .kind = .string },        .{ .name = "_GL_", .kind = .mutex },
        .{ .name = "_OSI", .kind = .method },
    };
    var at = root.first;
    for (want) |each| {
        const node = at orelse return error.TooFew;
        try testing.expectEqual(nameOf(each.name), node.name);
        try testing.expectEqual(each.kind, node.kind());
        at = node.next;
    }
    try testing.expectEqual(@as(?*Node, null), at);
    try testing.expectEqualStrings("Microsoft Windows NT", child(root, nameOf("_OS")).?.object.?.value.string.slice());
    try testing.expectEqual(@as(u64, 2), child(root, nameOf("_REV")).?.object.?.value.integer);
}

test "names are made in their scope, found exactly and by the search rules, and walked in order" {
    var test_machine: testmachine.TestMachine = .{};
    const ab = test_machine.base();
    try testing.expect(make(ab));
    defer discard(ab);
    const root = ab.root.?;
    const sb = child(root, nameOf("_SB")).?;
    var text: TextPath = undefined;
    try testing.expect(parseText("PCI0", &text));
    const pci = create(ab, sb, text.path, 1).made;
    try testing.expect(parseText("\\_SB.PCI0.LPC0", &text));
    const lpc = create(ab, root, text.path, 1).made;
    try testing.expect(parseText("_HID", &text));
    const hid = create(ab, pci, text.path, 1).made;
    try testing.expectEqual(hid, create(ab, pci, text.path, 2).there);
    try testing.expect(parseText("\\_SB.NONE.XXXX", &text));
    try testing.expectEqual(Made.missing, create(ab, root, text.path, 1));

    // Exactly: from the root, from a scope, and up from one.
    try testing.expect(parseText("\\_SB.PCI0.LPC0", &text));
    try testing.expectEqual(lpc, find(ab, root, text.path, .exact).?);
    try testing.expect(parseText("^_HID", &text));
    try testing.expectEqual(hid, find(ab, lpc, text.path, .exact).?);
    // A single name: only in the scope as written, and in the scopes
    // above it by the search rules.
    try testing.expect(parseText("_HID", &text));
    try testing.expectEqual(@as(?*Node, null), find(ab, lpc, text.path, .exact));
    try testing.expectEqual(hid, find(ab, lpc, text.path, .search).?);
    try testing.expect(parseText("_REV", &text));
    try testing.expectEqual(child(root, nameOf("_REV")).?, find(ab, lpc, text.path, .search).?);

    // The walk: the root's names, then down into \_SB in definition order.
    var order: [16]u32 = undefined;
    var count: usize = 0;
    var at = next(root, root);
    while (at) |node| : (at = next(root, node)) {
        if (node.parent == sb or node.parent == pci) {
            order[count] = node.name;
            count += 1;
        }
    }
    try testing.expectEqualSlices(u32, &.{ nameOf("PCI0"), nameOf("LPC0"), nameOf("_HID") }, order[0..count]);

    var shown: [64]u8 = undefined;
    const length = pathOf(lpc, &shown);
    try testing.expectEqualStrings("\\_SB.PCI0.LPC0", shown[0..length]);
    try testing.expectEqual(@as(u32, 2), depthOf(lpc));
    try testing.expectEqualStrings("\\", shown[0..pathOf(root, &shown)]);
}

test "an alias stands for its node" {
    var test_machine: testmachine.TestMachine = .{};
    const ab = test_machine.base();
    try testing.expect(make(ab));
    defer discard(ab);
    const root = ab.root.?;
    var text: TextPath = undefined;
    try testing.expect(parseText("\\_SB.DEV0", &text));
    const device = create(ab, root, text.path, 1).made;
    device.object = object.make(ab, .{ .device = {} });
    try testing.expect(parseText("\\_SB.ALS0", &text));
    const alias = create(ab, root, text.path, 1).made;
    alias.object = object.make(ab, .{ .alias = device });
    try testing.expect(parseText("\\_SB.DEV0.CHLD", &text));
    const inside = create(ab, root, text.path, 1).made;
    try testing.expect(parseText("\\_SB.ALS0", &text));
    try testing.expectEqual(device, find(ab, root, text.path, .exact).?);
    try testing.expect(parseText("\\_SB.ALS0.CHLD", &text));
    try testing.expectEqual(inside, find(ab, root, text.path, .exact).?);
}
