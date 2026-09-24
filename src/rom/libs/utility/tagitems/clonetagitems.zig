// SPDX-License-Identifier: MPL-2.0
//! CloneTagItems: a flat copy of a tag list - the items `NextTagItem`
//! finds, then TAG_DONE - in memory from `AllocateTagItems`.

const sdk = @import("sdk");
const _tagitems = @import("_tagitems.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const TagItem = sdk.utility.TagItem;

/// Makes a flat copy of a tag list.
///
/// SYNOPSIS:
/// ```zig
/// fn CloneTagItems(ub: *UtilityBase, tag_list: ?[*]const TagItem) ?[*]TagItem
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `tag_list` - the list to copy. Null gives a list holding only
///   `TAG_DONE`.
///
/// RESULT:
/// The copy, or null without memory.
///
/// BEHAVIOR:
/// The copy holds the items `NextTagItem` finds, in order, in one array
/// ended by `TAG_DONE`: the control items are gone and a `TAG_MORE` chain
/// is
/// joined into one. The data is copied as it stands - what a data word
/// points to is not. Later changes to the original are not seen;
/// `RefreshTagItemClones` copies them into the same array again.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It allocates, and `AllocMem` takes Forbid.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller owns the copy and gives it back with `FreeTagItems`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RefreshTagItemClones`, `FreeTagItems`, `AllocateTagItems`
///
/// EXAMPLES:
/// ```zig
/// const copy = ub.CloneTagItems(tags) orelse return error.NoMemory;
/// defer ub.FreeTagItems(copy);
/// ```
pub fn CloneTagItems(ub: *UtilityBase, tag_list: ?[*]const TagItem) ?[*]TagItem {
    const utility = ub.iface();
    const clone = utility.AllocateTagItems(@intCast(_tagitems.countTagItems(ub, tag_list) + 1)) orelse return null;
    utility.RefreshTagItemClones(clone, tag_list);
    return clone;
}
