// SPDX-License-Identifier: MPL-2.0
//! RefreshTagItemClones: copies a tag list flat into a clone again, as
//! `CloneTagItems` filled it first.

const std = @import("std");
const sdk = @import("sdk");

const UtilityBase = @import("../utility.zig").UtilityBase;
const TagItem = sdk.utility.TagItem;
const TAG_IGNORE = sdk.utility.TAG_IGNORE;
const TAG_MORE = sdk.utility.TAG_MORE;
const TAG_USER = sdk.utility.TAG_USER;

/// Copies a tag list into an earlier clone of it again.
///
/// SYNOPSIS:
/// ```zig
/// fn RefreshTagItemClones(ub: *UtilityBase, clone: ?[*]TagItem, original: ?[*]const TagItem) void
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// - `clone` - an array from `CloneTagItems` of this list. Null does
///   nothing.
/// - `original` - the list. Null leaves the clone holding only `TAG_DONE`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The same flat copy `CloneTagItems` makes, into the array it made, so a
/// holder of the clone sees the original's current values without a new
/// allocation.
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
/// NOTES:
/// The clone must have room: the original may not hold more items now than
/// when it was cloned. Nothing checks this.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloneTagItems`
///
/// EXAMPLES:
/// ```zig
/// ub.RefreshTagItemClones(copy, tags);
/// ```
pub fn RefreshTagItemClones(ub: *UtilityBase, clone: ?[*]TagItem, original: ?[*]const TagItem) void {
    const utility = ub.iface();
    var dest = clone orelse return;
    var scan = original;
    while (utility.NextTagItem(&scan)) |item| {
        dest[0] = item.*;
        dest += 1;
    }
    dest[0] = .{};
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

test "RefreshTagItemClones" {
    const ub = try library.setUp();
    defer kexec.deinit();
    // Flat: TAG_IGNORE and TAG_MORE are gone in the clone.
    const more = [_]TagItem{ .{ .tag = TAG_USER + 5, .data = 50 }, .{} };
    const source = [_]TagItem{ .{ .tag = TAG_IGNORE }, .{ .tag = TAG_USER + 4, .data = 40 }, .{ .tag = TAG_MORE, .data = @intFromPtr(&more) } };
    var clone: [3]TagItem = undefined;
    RefreshTagItemClones(ub, &clone, &source);
    try testing.expectEqualSlices(TagItem, &.{ .{ .tag = TAG_USER + 4, .data = 40 }, .{ .tag = TAG_USER + 5, .data = 50 }, .{} }, &clone);
    RefreshTagItemClones(ub, &clone, null);
    try testing.expectEqual(TagItem{}, clone[0]);
    try library.tearDown(ub);
}
