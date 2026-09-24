// SPDX-License-Identifier: MPL-2.0
//! TagInArray: whether a tag is in an array of tags that TAG_DONE ends.

const std = @import("std");
const sdk = @import("sdk");

const UtilityBase = @import("../utility.zig").UtilityBase;
const Tag = sdk.utility.Tag;
const TAG_DONE = sdk.utility.TAG_DONE;
const TAG_USER = sdk.utility.TAG_USER;

/// Tells whether a tag is in an array of tags.
///
/// SYNOPSIS:
/// ```zig
/// fn TagInArray(_: *UtilityBase, tag_val: Tag, tag_array: ?[*]const Tag) bool
/// ```
///
/// SINCE: 1.0. LVO -60.
///
/// INPUTS:
/// - `tag_val` - the tag to look for.
/// - `tag_array` - plain tags, not tag items, ended by `TAG_DONE`. Null is
///   an empty array.
///
/// RESULT:
/// True if the array has the tag.
///
/// BEHAVIOR:
/// A plain scan. An array of tags has no control tags, and `TAG_DONE`
/// itself cannot be looked for, since it ends the array.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads only its inputs and allocates nothing.
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
/// `FilterTagItems`, `FindTagItem`
///
/// EXAMPLES:
/// ```zig
/// const allowed = [_]Tag{ NP_Name, NP_StackSize, TAG_DONE };
/// if (ub.TagInArray(item.tag, &allowed)) keep(item);
/// ```
pub fn TagInArray(_: *UtilityBase, tag_val: Tag, tag_array: ?[*]const Tag) bool {
    var array = tag_array orelse return false;
    while (array[0] != TAG_DONE) : (array += 1) {
        if (array[0] == tag_val) return true;
    }
    return false;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "TagInArray" {
    const ub: *UtilityBase = undefined; // the tag calls never read it
    const array = [_]Tag{ TAG_USER + 1, TAG_USER + 7, TAG_DONE };
    try testing.expect(TagInArray(ub, TAG_USER + 7, &array));
    try testing.expect(!TagInArray(ub, TAG_USER + 2, &array));
    try testing.expect(!TagInArray(ub, TAG_USER + 1, null));
}
