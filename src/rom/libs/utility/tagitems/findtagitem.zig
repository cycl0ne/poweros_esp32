// SPDX-License-Identifier: MPL-2.0
//! FindTagItem: the first item of a tag list with a given tag, found with
//! `NextTagItem`.

const std = @import("std");
const sdk = @import("sdk");

const UtilityBase = @import("../utility.zig").UtilityBase;
const Tag = sdk.utility.Tag;
const TagItem = sdk.utility.TagItem;
const TAG_MORE = sdk.utility.TAG_MORE;
const TAG_USER = sdk.utility.TAG_USER;
const GetTagData = @import("gettagdata.zig").GetTagData;

/// Finds the first item of a tag list with a given tag.
///
/// SYNOPSIS:
/// ```zig
/// fn FindTagItem(ub: *UtilityBase, tag_val: Tag, tag_list: ?[*]const TagItem) ?*const TagItem
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `tag_val` - the tag to find. A control tag (`TAG_DONE`, `TAG_IGNORE`,
///   `TAG_SKIP`, `TAG_MORE`) is never found.
/// - `tag_list` - the list. Null is an empty list.
///
/// RESULT:
/// The item, or null if the list does not have the tag.
///
/// BEHAVIOR:
/// The list is walked with `NextTagItem`, so `TAG_MORE` is followed and the
/// control items are passed over. The first item with the tag wins: a list
/// that gives the same tag twice means the earlier one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself; it allocates nothing. The lists are the
///   caller's, and so is keeping others off them.
/// - Forbid: not needed, and not taken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The item belongs to the list and lives as long as
/// the list does.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetTagData`, `NextTagItem`, `TagInArray`
///
/// EXAMPLES:
/// ```zig
/// if (ub.FindTagItem(NP_Name, tags)) |item| {
///     name = @ptrFromInt(item.data);
/// }
/// ```
pub fn FindTagItem(ub: *UtilityBase, tag_val: Tag, tag_list: ?[*]const TagItem) ?*const TagItem {
    const utility = ub.iface();
    var scan = tag_list;
    while (utility.NextTagItem(&scan)) |item| {
        if (item.tag == tag_val) return item;
    }
    return null;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

test "FindTagItem and GetTagData" {
    const ub = try library.setUp();
    defer kexec.deinit();
    const more = [_]TagItem{ .{ .tag = TAG_USER + 2, .data = 22 }, .{} };
    const list = [_]TagItem{
        .{ .tag = TAG_USER + 1, .data = 11 },
        .{ .tag = TAG_USER + 1, .data = 12 },
        .{ .tag = TAG_MORE, .data = @intFromPtr(&more) },
    };
    try testing.expectEqual(&list[0], FindTagItem(ub, TAG_USER + 1, &list).?);
    try testing.expectEqual(&more[0], FindTagItem(ub, TAG_USER + 2, &list).?);
    try testing.expect(FindTagItem(ub, TAG_USER + 3, &list) == null);
    try testing.expectEqual(@as(usize, 22), GetTagData(ub, TAG_USER + 2, 5, &list));
    try testing.expectEqual(@as(usize, 5), GetTagData(ub, TAG_USER + 3, 5, &list));
    try testing.expectEqual(@as(usize, 5), GetTagData(ub, TAG_USER + 1, 5, null));
    try library.tearDown(ub);
}
