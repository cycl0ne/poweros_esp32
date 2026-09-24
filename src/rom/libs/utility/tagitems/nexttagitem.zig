// SPDX-License-Identifier: MPL-2.0
//! NextTagItem: the next item a tag list holds. It follows TAG_MORE and
//! passes over TAG_IGNORE and TAG_SKIP; every other walk over a list is
//! built on it.

const std = @import("std");
const sdk = @import("sdk");
const _tagitems = @import("_tagitems.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const TagItem = sdk.utility.TagItem;
const TAG_DONE = sdk.utility.TAG_DONE;
const TAG_IGNORE = sdk.utility.TAG_IGNORE;
const TAG_MORE = sdk.utility.TAG_MORE;
const TAG_SKIP = sdk.utility.TAG_SKIP;
const TAG_USER = sdk.utility.TAG_USER;

/// Returns the next item a tag list holds, and moves the caller's place in
/// the list past it.
///
/// SYNOPSIS:
/// ```zig
/// fn NextTagItem(_: *UtilityBase, tag_list_ptr: *?[*]const TagItem) ?*const TagItem
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `tag_list_ptr` - where the caller keeps its place: at first the list
///   itself, then whatever this call left there. Null means the end.
///
/// RESULT:
/// The next item with a tag of its own, or null at the end of the list -
/// and then `*tag_list_ptr` is null too.
///
/// BEHAVIOR:
/// The control tags are followed, never returned:
///
/// - `TAG_DONE` ends the list.
/// - `TAG_IGNORE` passes over its own item.
/// - `TAG_SKIP` passes over itself and the `ti_Data` items behind it.
/// - `TAG_MORE` goes on at the array its `ti_Data` points to; a null there
///   ends the list.
///
/// Every other tag is returned. A list is walked by calling this until it
/// returns null, never by indexing the array: `TAG_MORE` can continue the
/// list anywhere, and what lies behind it in the array is not the list's.
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
/// NOTES:
/// Nothing guards against a `TAG_MORE` chain that leads back into itself;
/// such a list is walked for ever.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindTagItem`, `GetTagData`, `CloneTagItems`
///
/// EXAMPLES:
/// ```zig
/// var place: ?[*]const TagItem = tags;
/// while (ub.NextTagItem(&place)) |item| {
///     switch (item.tag) {
///         MY_Width => width = item.data,
///         else => {},
///     }
/// }
/// ```
pub fn NextTagItem(_: *UtilityBase, tag_list_ptr: *?[*]const TagItem) ?*const TagItem {
    var list = tag_list_ptr.* orelse return null;
    while (true) {
        const item = &list[0];
        switch (item.tag) {
            TAG_DONE => break,
            TAG_IGNORE => list += 1,
            TAG_SKIP => list += item.data + 1,
            TAG_MORE => list = @as(?[*]const TagItem, @ptrFromInt(item.data)) orelse break,
            else => {
                tag_list_ptr.* = list + 1;
                return item;
            },
        }
    }
    tag_list_ptr.* = null;
    return null;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

test "NextTagItem: TAG_IGNORE, TAG_SKIP and TAG_MORE" {
    const ub = try library.setUp();
    defer kexec.deinit();
    const second = [_]TagItem{ .{ .tag = TAG_USER + 3, .data = 30 }, .{} };
    const first = [_]TagItem{
        .{ .tag = TAG_USER + 1, .data = 10 },
        .{ .tag = TAG_IGNORE, .data = 99 },
        .{ .tag = TAG_SKIP, .data = 1 },
        .{ .tag = TAG_USER + 9, .data = 90 }, // skipped
        .{ .tag = TAG_USER + 2, .data = 20 },
        .{ .tag = TAG_MORE, .data = @intFromPtr(&second) },
        .{ .tag = TAG_USER + 8 }, // behind TAG_MORE: never read
    };
    try _tagitems.expectTags(ub, &first, &.{ TAG_USER + 1, TAG_USER + 2, TAG_USER + 3 });

    // TAG_MORE to null ends the list; so does a null list.
    const cut = [_]TagItem{ .{ .tag = TAG_USER + 1 }, .{ .tag = TAG_MORE, .data = 0 } };
    try _tagitems.expectTags(ub, &cut, &.{TAG_USER + 1});
    try _tagitems.expectTags(ub, null, &.{});
    try testing.expectEqual(@as(usize, 3), _tagitems.countTagItems(ub, &first));
    try library.tearDown(ub);
}
