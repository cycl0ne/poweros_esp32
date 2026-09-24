// SPDX-License-Identifier: MPL-2.0
//! PackBoolTags: turns boolean tags into flag bits, through a map from
//! each tag to its bits.

const std = @import("std");
const sdk = @import("sdk");

const UtilityBase = @import("../utility.zig").UtilityBase;
const TagItem = sdk.utility.TagItem;
const TAG_USER = sdk.utility.TAG_USER;

/// Sets and clears flag bits from the boolean tags of a list.
///
/// SYNOPSIS:
/// ```zig
/// fn PackBoolTags(ub: *UtilityBase, initial_flags: u32, tag_list: ?[*]const TagItem, bool_map: ?[*]const TagItem) u32
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `initial_flags` - the flags to start from.
/// - `tag_list` - the boolean tags: non-zero data is true, zero is false.
/// - `bool_map` - a tag list with, for each boolean tag, the bits it stands
///   for in its `ti_Data`. Only the low 32 bits count.
///
/// RESULT:
/// `initial_flags` with the mapped bits set or cleared.
///
/// BEHAVIOR:
/// Every item of `tag_list` whose tag the map has sets its bits when its
/// data is non-zero and clears them when it is zero. Items apply in list
/// order, so of two items for the same bits the later one wins. A tag the
/// map does not have changes nothing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself; it allocates nothing. The lists are the
///   caller's, and so is keeping others off them.
/// - Forbid: not needed, and not taken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindTagItem`, `PackStructureTags`
///
/// EXAMPLES:
/// ```zig
/// const map = [_]TagItem{
///     .{ .tag = MY_Visible, .data = MYF_VISIBLE },
///     .{ .tag = MY_Locked, .data = MYF_LOCKED },
///     .{},
/// };
/// flags = ub.PackBoolTags(flags, tags, &map);
/// ```
pub fn PackBoolTags(ub: *UtilityBase, initial_flags: u32, tag_list: ?[*]const TagItem, bool_map: ?[*]const TagItem) u32 {
    const utility = ub.iface();
    var flags = initial_flags;
    var scan = tag_list;
    while (utility.NextTagItem(&scan)) |item| {
        const bits: u32 = @truncate((utility.FindTagItem(item.tag, bool_map) orelse continue).data);
        if (item.data != 0) flags |= bits else flags &= ~bits;
    }
    return flags;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

test "PackBoolTags sets and clears the mapped bits" {
    const ub = try library.setUp();
    defer kexec.deinit();
    const map = [_]TagItem{ .{ .tag = TAG_USER + 1, .data = 0x1 }, .{ .tag = TAG_USER + 2, .data = 0x6 }, .{} };
    const list = [_]TagItem{
        .{ .tag = TAG_USER + 1, .data = 1 },
        .{ .tag = TAG_USER + 2, .data = 0 },
        .{ .tag = TAG_USER + 9, .data = 1 }, // not in the map
        .{},
    };
    try testing.expectEqual(@as(u32, 0x81), PackBoolTags(ub, 0x86, &list, &map));
    try library.tearDown(ub);
}
