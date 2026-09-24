// SPDX-License-Identifier: MPL-2.0
//! FilterTagItems: keeps the items whose tags are (TAGFILTER_AND) or are
//! not (TAGFILTER_NOT) in an array; the others become TAG_IGNORE.

const std = @import("std");
const sdk = @import("sdk");
const _tagitems = @import("_tagitems.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const Tag = sdk.utility.Tag;
const TagItem = sdk.utility.TagItem;
const TAG_DONE = sdk.utility.TAG_DONE;
const TAG_IGNORE = sdk.utility.TAG_IGNORE;
const TAG_USER = sdk.utility.TAG_USER;
const TAGFILTER_AND = sdk.utility.TAGFILTER_AND;
const TAGFILTER_NOT = sdk.utility.TAGFILTER_NOT;

/// Keeps the items of a list whose tags are, or are not, in an array.
///
/// SYNOPSIS:
/// ```zig
/// fn FilterTagItems(ub: *UtilityBase, tag_list: ?[*]TagItem, filter_array: ?[*]const Tag, logic: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -64.
///
/// INPUTS:
/// - `tag_list` - the list to filter, in place.
/// - `filter_array` - tags ended by `TAG_DONE`. Null holds no tags.
/// - `logic` - `TAGFILTER_AND` keeps the tags in the array,
///   `TAGFILTER_NOT` those that are not.
///
/// RESULT:
/// How many items were kept.
///
/// BEHAVIOR:
/// An item that is not kept becomes `TAG_IGNORE`, so the array keeps its
/// length and every `TAG_MORE` stays where it is.
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
/// Any `logic` other than `TAGFILTER_AND` works as `TAGFILTER_NOT`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `TagInArray`, `MapTags`
///
/// EXAMPLES:
/// ```zig
/// const not_allowed = [_]Tag{ NP_Entry, NP_Seglist, TAG_DONE };
/// _ = ub.FilterTagItems(copy, &not_allowed, TAGFILTER_NOT);
/// ```
pub fn FilterTagItems(ub: *UtilityBase, tag_list: ?[*]TagItem, filter_array: ?[*]const Tag, logic: u32) u32 {
    const utility = ub.iface();
    var kept: u32 = 0;
    var scan: ?[*]const TagItem = tag_list;
    while (_tagitems.nextMutable(ub, &scan)) |item| {
        if (utility.TagInArray(item.tag, filter_array) == (logic == TAGFILTER_AND)) {
            kept += 1;
        } else {
            item.tag = TAG_IGNORE;
        }
    }
    return kept;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

test "FilterTagItems keeps or drops the tags in the array" {
    const ub = try library.setUp();
    defer kexec.deinit();
    const array = [_]Tag{ TAG_USER + 2, TAG_DONE };
    var list = [_]TagItem{ .{ .tag = TAG_USER + 1 }, .{ .tag = TAG_USER + 2 }, .{ .tag = TAG_USER + 3 }, .{} };
    const original = list;
    try testing.expectEqual(@as(u32, 1), FilterTagItems(ub, &list, &array, TAGFILTER_AND));
    try _tagitems.expectTags(ub, &list, &.{TAG_USER + 2});

    list = original;
    try testing.expectEqual(@as(u32, 2), FilterTagItems(ub, &list, &array, TAGFILTER_NOT));
    try _tagitems.expectTags(ub, &list, &.{ TAG_USER + 1, TAG_USER + 3 });

    list = original;
    try testing.expectEqual(@as(u32, 3), FilterTagItems(ub, &list, null, TAGFILTER_NOT));
    try library.tearDown(ub);
}
