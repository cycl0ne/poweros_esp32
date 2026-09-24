// SPDX-License-Identifier: MPL-2.0
//! MapTags: renames the tags of a list through a map; what the map does not
//! have is kept or dropped as the map type says.

const std = @import("std");
const sdk = @import("sdk");
const _tagitems = @import("_tagitems.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const TagItem = sdk.utility.TagItem;
const TAG_DONE = sdk.utility.TAG_DONE;
const TAG_IGNORE = sdk.utility.TAG_IGNORE;
const TAG_USER = sdk.utility.TAG_USER;
const MAP_REMOVE_NOT_FOUND = sdk.utility.MAP_REMOVE_NOT_FOUND;
const MAP_KEEP_NOT_FOUND = sdk.utility.MAP_KEEP_NOT_FOUND;

/// Renames the tags of a list through a map.
///
/// SYNOPSIS:
/// ```zig
/// fn MapTags(ub: *UtilityBase, tag_list: ?[*]TagItem, map_list: ?[*]const TagItem, map_type: u32) void
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `tag_list` - the list to change, in place.
/// - `map_list` - pairs of old tag (`ti_Tag`) and new tag (`ti_Data`). A
///   new tag of `TAG_DONE` removes the item. Null maps nothing.
/// - `map_type` - `MAP_KEEP_NOT_FOUND` keeps a tag the map does not have,
///   `MAP_REMOVE_NOT_FOUND` removes it.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A removed item becomes `TAG_IGNORE` rather than being cut out, so the
/// array keeps its length and every `TAG_MORE` stays where it is. The data
/// of an item is never changed. With a null map and `MAP_REMOVE_NOT_FOUND`
/// every item goes.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself; it allocates nothing. The lists are the
///   caller's, and so is keeping others off them.
/// - Forbid: not needed, and not taken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The list is written in place, so it may not be
/// read-only.
///
/// NOTES:
/// Any `map_type` other than `MAP_REMOVE_NOT_FOUND` keeps the tag.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FilterTagItems`, `FindTagItem`
///
/// EXAMPLES:
/// ```zig
/// const to_gadget = [_]TagItem{ .{ .tag = MY_Left, .data = GA_Left }, .{} };
/// ub.MapTags(tags, &to_gadget, MAP_KEEP_NOT_FOUND);
/// ```
pub fn MapTags(ub: *UtilityBase, tag_list: ?[*]TagItem, map_list: ?[*]const TagItem, map_type: u32) void {
    const utility = ub.iface();
    var scan: ?[*]const TagItem = tag_list;
    while (_tagitems.nextMutable(ub, &scan)) |item| {
        if (utility.FindTagItem(item.tag, map_list)) |entry| {
            item.tag = if (entry.data == TAG_DONE) TAG_IGNORE else @truncate(entry.data);
        } else if (map_type == MAP_REMOVE_NOT_FOUND) {
            item.tag = TAG_IGNORE;
        }
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

test "MapTags renames, removes, and keeps or drops the unmapped" {
    const ub = try library.setUp();
    defer kexec.deinit();
    const map = [_]TagItem{ .{ .tag = TAG_USER + 1, .data = TAG_USER + 10 }, .{ .tag = TAG_USER + 2, .data = TAG_DONE }, .{} };
    var list = [_]TagItem{ .{ .tag = TAG_USER + 1, .data = 1 }, .{ .tag = TAG_USER + 2 }, .{ .tag = TAG_USER + 3 }, .{} };
    const original = list;
    MapTags(ub, &list, &map, MAP_KEEP_NOT_FOUND);
    try _tagitems.expectTags(ub, &list, &.{ TAG_USER + 10, TAG_USER + 3 });
    try testing.expectEqual(@as(usize, 1), list[0].data);

    list = original;
    MapTags(ub, &list, &map, MAP_REMOVE_NOT_FOUND);
    try _tagitems.expectTags(ub, &list, &.{TAG_USER + 10});

    list = original;
    MapTags(ub, &list, null, MAP_REMOVE_NOT_FOUND);
    try _tagitems.expectTags(ub, &list, &.{});
    try library.tearDown(ub);
}
