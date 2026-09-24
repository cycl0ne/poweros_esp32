// SPDX-License-Identifier: MPL-2.0
//! FilterTagChanges: drops the changes that change nothing, and with
//! `apply` writes the rest into the original list.

const std = @import("std");
const sdk = @import("sdk");
const _tagitems = @import("_tagitems.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const TagItem = sdk.utility.TagItem;
const TAG_IGNORE = sdk.utility.TAG_IGNORE;
const TAG_USER = sdk.utility.TAG_USER;

/// Drops the changes in a change list that change nothing, and can apply
/// the rest.
///
/// SYNOPSIS:
/// ```zig
/// fn FilterTagChanges(ub: *UtilityBase, change_list: ?[*]TagItem, original_list: ?[*]TagItem, apply: u32) void
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `change_list` - the proposed changes. Changed in place.
/// - `original_list` - the current values. Changed in place when `apply` is
///   set.
/// - `apply` - non-zero writes each remaining change into the original.
///
/// RESULT:
/// Nothing. `change_list` now holds only the real changes and the tags the
/// original does not have.
///
/// BEHAVIOR:
/// A change is compared with the first item of the original that has its
/// tag:
///
/// - **Same data:** the change becomes `TAG_IGNORE`.
/// - **Other data:** the change stays; with `apply` the original item takes
///   the new data.
/// - **Tag not in the original:** the change stays and nothing is applied -
///   it is a change, but there is nowhere to put it.
///
/// What is left is exactly what changed, which is what an object needs in
/// order to tell others about an update and stay quiet about the rest.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself; it allocates nothing. The lists are the
///   caller's, and so is keeping others off them.
/// - Forbid: not needed, and not taken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. Both lists are written in place, so neither may be
/// read-only.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ApplyTagChanges`, `FindTagItem`
///
/// EXAMPLES:
/// ```zig
/// ub.FilterTagChanges(changes, current, 1);
/// var place: ?[*]const TagItem = changes;
/// while (ub.NextTagItem(&place)) |item| notify(item);
/// ```
pub fn FilterTagChanges(ub: *UtilityBase, change_list: ?[*]TagItem, original_list: ?[*]TagItem, apply: u32) void {
    const utility = ub.iface();
    var scan: ?[*]const TagItem = change_list;
    while (_tagitems.nextMutable(ub, &scan)) |change| {
        const original = @constCast(utility.FindTagItem(change.tag, original_list) orelse continue);
        if (original.data == change.data) {
            change.tag = TAG_IGNORE;
        } else if (apply != 0) {
            original.data = change.data;
        }
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

test "FilterTagChanges drops what changes nothing, applies the rest" {
    const ub = try library.setUp();
    defer kexec.deinit();
    var original = [_]TagItem{ .{ .tag = TAG_USER + 1, .data = 1 }, .{ .tag = TAG_USER + 2, .data = 2 }, .{} };
    var changes = [_]TagItem{
        .{ .tag = TAG_USER + 1, .data = 1 }, // the same: dropped
        .{ .tag = TAG_USER + 2, .data = 5 },
        .{ .tag = TAG_USER + 3, .data = 7 }, // not in the original: kept
        .{},
    };
    const unchanged = changes;
    FilterTagChanges(ub, &changes, &original, 0);
    try _tagitems.expectTags(ub, &changes, &.{ TAG_USER + 2, TAG_USER + 3 });
    try testing.expectEqual(@as(usize, 2), original[1].data);

    changes = unchanged;
    FilterTagChanges(ub, &changes, &original, 1);
    try testing.expectEqual(@as(usize, 5), original[1].data);
    try library.tearDown(ub);
}
