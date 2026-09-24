// SPDX-License-Identifier: MPL-2.0
//! What the tag-list calls share: `nextMutable`, NextTagItem on a list the
//! caller may change, and `countTagItems`, plus the tests' `expectTags`.

const std = @import("std");
const sdk = @import("sdk");

const UtilityBase = @import("../utility.zig").UtilityBase;
const Tag = sdk.utility.Tag;
const TagItem = sdk.utility.TagItem;
const NextTagItem = @import("nexttagitem.zig").NextTagItem;

/// `NextTagItem` on a list the caller may change: the same walk, with the
/// item handed back writable.
///
/// INPUTS:
/// - `ub` - the library, called through for `NextTagItem`.
/// - `tag_list_ptr` - the caller's place in the list, as for `NextTagItem`.
pub fn nextMutable(ub: *UtilityBase, tag_list_ptr: *?[*]const TagItem) ?*TagItem {
    const utility = ub.iface();
    return @constCast(utility.NextTagItem(tag_list_ptr));
}

/// How many items `NextTagItem` finds in a list: the items a flat copy
/// needs, before its `TAG_DONE`.
///
/// INPUTS:
/// - `ub` - the library, called through for `NextTagItem`.
/// - `tag_list` - the list; null counts 0.
pub fn countTagItems(ub: *UtilityBase, tag_list: ?[*]const TagItem) usize {
    const utility = ub.iface();
    var count: usize = 0;
    var scan = tag_list;
    while (utility.NextTagItem(&scan)) |_| count += 1;
    return count;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

/// Asserts that walking a list gives exactly `expected`, in order, and
/// then the end. For the tests in this folder.
///
/// INPUTS:
/// - `ub` - the library the walk is done with.
/// - `tag_list` - the list.
/// - `expected` - the tags it should give.
pub fn expectTags(ub: *UtilityBase, tag_list: ?[*]const TagItem, expected: []const Tag) !void {
    var scan = tag_list;
    for (expected) |tag| try testing.expectEqual(tag, NextTagItem(ub, &scan).?.tag);
    try testing.expect(NextTagItem(ub, &scan) == null);
    try testing.expect(scan == null);
}
