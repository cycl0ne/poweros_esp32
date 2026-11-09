// SPDX-License-Identifier: MIT
//! The list Mesa's V3D compiler keeps its blocks and their instructions
//! in: the port of Mesa's src/util/list.h. A list is linked both ways
//! around a head of its own, the head being a `Link` like each element's,
//! and is empty where the head is linked to itself. Putting something
//! after or before a link works the same at the head as at an element,
//! which is what the compiler's cursors stand on (vir.zig).
//!
//! An element holds its `Link` as a field and is had back from it with
//! @fieldParentPtr, as list_entry() has it from offsetof().

const std = @import("std");
const assert = std.debug.assert;

pub const Link = struct {
    prev: ?*Link = null,
    next: ?*Link = null,

    /// An empty list's head (list_inithead, list.h:58).
    pub fn initHead(item: *Link) void {
        item.prev = item;
        item.next = item;
    }

    /// `item` put right after `list`, which is the front where `list` is a
    /// head (list_add, list.h:71).
    pub fn add(item: *Link, list: *Link) void {
        item.prev = list;
        item.next = list.next;
        list.next.?.prev = item;
        list.next = item;
    }

    /// `item` put right before `list`, which is the end where `list` is a
    /// head (list_addtail, list.h:86).
    pub fn addTail(item: *Link, list: *Link) void {
        item.next = list;
        item.prev = list.prev;
        list.prev.?.next = item;
        list.prev = item;
    }

    /// What `from` heads, headed by `to` instead (list_replace, list.h:98).
    pub fn replace(from: *Link, to: *Link) void {
        if (from.isEmpty()) {
            to.initHead();
        } else {
            to.prev = from.prev;
            to.next = from.next;
            from.next.?.prev = to;
            from.prev.?.next = to;
        }
    }

    /// `item` taken out, and linked to nothing (list_del, list.h:111).
    pub fn del(item: *Link) void {
        item.prev.?.next = item.next;
        item.next.?.prev = item.prev;
        item.prev = null;
        item.next = null;
    }

    /// `item` taken out, and left an empty list's head (list_delinit,
    /// list.h:119).
    pub fn delInit(item: *Link) void {
        item.prev.?.next = item.next;
        item.next.?.prev = item.prev;
        item.next = item;
        item.prev = item;
    }

    /// list_is_empty (list.h:128).
    pub fn isEmpty(list: *const Link) bool {
        return list.next == list;
    }

    /// In a list, or a list's head (list_is_linked, list.h:134).
    pub fn isLinked(list: *const Link) bool {
        assert((list.prev != null) == (list.next != null));
        return list.next != null;
    }

    /// A list of exactly one (list_is_singular, list.h:146).
    pub fn isSingular(list: *const Link) bool {
        return list.isLinked() and !list.isEmpty() and list.next.?.next == list;
    }

    /// list_length (list.h:153).
    pub fn length(list: *const Link) u32 {
        var count: u32 = 0;
        var node = list.next.?;
        while (node != list) : (node = node.next.?) count += 1;
        return count;
    }

    /// What `src` heads, put at the front of what `dst` heads, `src` left
    /// as it was (list_splice, list.h:163).
    pub fn splice(src: *Link, dst: *Link) void {
        if (src.isEmpty()) return;
        src.next.?.prev = dst;
        src.prev.?.next = dst.next;
        dst.next.?.prev = src.prev;
        dst.next = src.next;
    }

    /// The same at the end of what `dst` heads (list_splicetail,
    /// list.h:175).
    pub fn spliceTail(src: *Link, dst: *Link) void {
        if (src.isEmpty()) return;
        src.prev.?.next = dst;
        src.next.?.prev = dst.prev;
        dst.prev.?.next = src.next;
        dst.prev = src.prev;
    }

    /// `item` taken from wherever it is and put right after `loc`
    /// (list_move_to, list.h:205). Mesa's comment says in front of it;
    /// its code, which this is, puts it after.
    pub fn moveTo(item: *Link, loc: *Link) void {
        item.del();
        item.add(loc);
    }
};

/// The element a link is the `field` of (list_entry, list.h:211).
pub fn entry(comptime T: type, comptime field: []const u8, link: *Link) *T {
    return @fieldParentPtr(field, link);
}

/// The first element of what `head` heads (list_first_entry).
pub fn firstEntry(comptime T: type, comptime field: []const u8, head: *const Link) *T {
    return entry(T, field, head.next.?);
}

/// The last (list_last_entry).
pub fn lastEntry(comptime T: type, comptime field: []const u8, head: *const Link) *T {
    return entry(T, field, head.prev.?);
}

pub const Direction = enum { forward, backward };

fn step(link: *Link, comptime direction: Direction) *Link {
    return switch (direction) {
        .forward => link.next.?,
        .backward => link.prev.?,
    };
}

/// The elements from one link on to the head, each read from the one
/// before after the caller is done with that one, as Mesa's
/// list_for_each_entry, _rev, _from and _from_rev read it (list.h:257-
/// 306): what is put right after the current element is visited, and the
/// current element may not be taken out.
pub fn Each(comptime T: type, comptime field: []const u8, comptime direction: Direction) type {
    return struct {
        head: *const Link,
        /// The element answered last, or the one to answer first.
        pos: *Link,
        started: bool = false,

        pub fn next(it: *@This()) ?*T {
            if (it.started) {
                if (it.pos == it.head) return null;
                it.pos = step(it.pos, direction);
            }
            it.started = true;
            if (it.pos == it.head) return null;
            return entry(T, field, it.pos);
        }
    };
}

/// The same, with each element's follower read before the caller has the
/// element, as list_for_each_entry_safe, _safe_rev and _from_safe read it:
/// the current element may be taken out, and what is put right after it
/// is not visited.
pub fn EachSafe(comptime T: type, comptime field: []const u8, comptime direction: Direction) type {
    return struct {
        head: *const Link,
        pos: *Link,

        pub fn next(it: *@This()) ?*T {
            if (it.pos == it.head) return null;
            const item = entry(T, field, it.pos);
            it.pos = step(it.pos, direction);
            return item;
        }
    };
}

const testing = std.testing;

const Item = struct {
    value: u32,
    link: Link = .{},
};

fn expectOrder(head: *Link, values: []const u32) !void {
    try testing.expectEqual(@as(u32, @intCast(values.len)), head.length());
    var forward = Each(Item, "link", .forward){ .head = head, .pos = head.next.? };
    for (values) |value| try testing.expectEqual(value, forward.next().?.value);
    try testing.expectEqual(@as(?*Item, null), forward.next());
    var backward = Each(Item, "link", .backward){ .head = head, .pos = head.prev.? };
    var at = values.len;
    while (at > 0) {
        at -= 1;
        try testing.expectEqual(values[at], backward.next().?.value);
    }
    try testing.expectEqual(@as(?*Item, null), backward.next());
}

test "a list is linked as Mesa's list.h links it" {
    var head: Link = .{};
    head.initHead();
    try testing.expect(head.isEmpty());
    try testing.expect(head.isLinked());
    try testing.expect(!head.isSingular());

    var items: [5]Item = .{ .{ .value = 0 }, .{ .value = 1 }, .{ .value = 2 }, .{ .value = 3 }, .{ .value = 4 } };
    items[1].link.addTail(&head);
    try testing.expect(head.isSingular());
    items[2].link.addTail(&head);
    items[0].link.add(&head);
    try expectOrder(&head, &.{ 0, 1, 2 });
    try testing.expectEqual(&items[0], firstEntry(Item, "link", &head));
    try testing.expectEqual(&items[2], lastEntry(Item, "link", &head));

    // After a link and before one, wherever it is.
    items[3].link.add(&items[0].link);
    items[4].link.addTail(&items[0].link);
    try expectOrder(&head, &.{ 4, 0, 3, 1, 2 });

    items[3].link.del();
    try testing.expect(!items[3].link.isLinked());
    try expectOrder(&head, &.{ 4, 0, 1, 2 });
    items[4].link.delInit();
    try testing.expect(items[4].link.isEmpty());
    try expectOrder(&head, &.{ 0, 1, 2 });

    // list_move_to puts it after the link it is given.
    items[0].link.moveTo(&items[2].link);
    try expectOrder(&head, &.{ 1, 2, 0 });
}

test "lists are spliced, and a head replaced, as list.h does it" {
    var first: Link = .{};
    var second: Link = .{};
    first.initHead();
    second.initHead();
    var items: [4]Item = .{ .{ .value = 0 }, .{ .value = 1 }, .{ .value = 2 }, .{ .value = 3 } };
    items[0].link.addTail(&first);
    items[1].link.addTail(&first);
    items[2].link.addTail(&second);
    items[3].link.addTail(&second);

    second.splice(&first);
    try expectOrder(&first, &.{ 2, 3, 0, 1 });
    second.initHead();
    // An empty source changes nothing.
    second.spliceTail(&first);
    try expectOrder(&first, &.{ 2, 3, 0, 1 });

    var other: Link = .{};
    first.replace(&other);
    try expectOrder(&other, &.{ 2, 3, 0, 1 });
    var empty: Link = .{};
    second.replace(&empty);
    try testing.expect(empty.isEmpty());

    // And at the end.
    var tail: Link = .{};
    tail.initHead();
    var last = Item{ .value = 9 };
    last.link.addTail(&tail);
    tail.spliceTail(&other);
    try expectOrder(&other, &.{ 2, 3, 0, 1, 9 });
}

test "the safe walk lets the current element go; the plain one visits what is put after it" {
    var head: Link = .{};
    head.initHead();
    var items: [4]Item = .{ .{ .value = 0 }, .{ .value = 1 }, .{ .value = 2 }, .{ .value = 3 } };
    for (items[0..3]) |*item| item.link.addTail(&head);

    // Put 3 after 0 while at 0: the plain walk reads 0's follower after.
    var plain = Each(Item, "link", .forward){ .head = &head, .pos = head.next.? };
    var seen: [4]u32 = undefined;
    var count: usize = 0;
    while (plain.next()) |item| {
        if (item.value == 0) items[3].link.add(&item.link);
        seen[count] = item.value;
        count += 1;
    }
    try testing.expectEqualSlices(u32, &.{ 0, 3, 1, 2 }, seen[0..count]);

    // The safe walk had 0's follower before, and lets each go.
    var safe = EachSafe(Item, "link", .forward){ .head = &head, .pos = head.next.? };
    count = 0;
    while (safe.next()) |item| {
        seen[count] = item.value;
        count += 1;
        item.link.del();
    }
    try testing.expectEqualSlices(u32, &.{ 0, 3, 1, 2 }, seen[0..count]);
    try testing.expect(head.isEmpty());

    // Backwards and from an element.
    for (items[0..3]) |*item| item.link.addTail(&head);
    var from = Each(Item, "link", .backward){ .head = &head, .pos = &items[1].link };
    try testing.expectEqual(@as(u32, 1), from.next().?.value);
    try testing.expectEqual(@as(u32, 0), from.next().?.value);
    try testing.expectEqual(@as(?*Item, null), from.next());
    try testing.expectEqual(@as(?*Item, null), from.next());
}
