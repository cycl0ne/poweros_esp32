// SPDX-License-Identifier: MPL-2.0
//! ApplyTagChanges: every item of a list whose tag a change list has takes
//! the change's data.

const std = @import("std");
const sdk = @import("sdk");
const _tagitems = @import("_tagitems.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const TagItem = sdk.utility.TagItem;
const TAG_USER = sdk.utility.TAG_USER;

/// Gives every item of a list the data a change list has for its tag.
///
/// SYNOPSIS:
/// ```zig
/// fn ApplyTagChanges(ub: *UtilityBase, list: ?[*]TagItem, change_list: ?[*]const TagItem) void
/// ```
///
/// SINCE: 1.0. LVO -124.
///
/// INPUTS:
/// - `list` - the list to change, in place.
/// - `change_list` - the new data. Tags `list` does not have are ignored.
///   Null changes nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Each item takes the data of the first change with its tag. Unlike
/// `FilterTagChanges` it does not look at whether the data differs, and it
/// leaves the change list as it is.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself; it allocates nothing. The lists are the
///   caller's, and so is keeping others off them.
/// - Forbid: not needed, and not taken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. `list` is written in place, so it may not be
/// read-only.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FilterTagChanges`, `FindTagItem`
///
/// EXAMPLES:
/// ```zig
/// ub.ApplyTagChanges(current, changes);
/// ```
pub fn ApplyTagChanges(ub: *UtilityBase, list: ?[*]TagItem, change_list: ?[*]const TagItem) void {
    const utility = ub.iface();
    var scan: ?[*]const TagItem = list;
    while (_tagitems.nextMutable(ub, &scan)) |item| {
        if (utility.FindTagItem(item.tag, change_list)) |change| item.data = change.data;
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

test "ApplyTagChanges" {
    const ub = try library.setUp();
    defer kexec.deinit();
    var list = [_]TagItem{ .{ .tag = TAG_USER + 1, .data = 1 }, .{ .tag = TAG_USER + 2, .data = 2 }, .{} };
    const changes = [_]TagItem{ .{ .tag = TAG_USER + 2, .data = 20 }, .{ .tag = TAG_USER + 3, .data = 30 }, .{} };
    ApplyTagChanges(ub, &list, &changes);
    try testing.expectEqual(@as(usize, 1), list[0].data);
    try testing.expectEqual(@as(usize, 20), list[1].data);
    try library.tearDown(ub);
}
