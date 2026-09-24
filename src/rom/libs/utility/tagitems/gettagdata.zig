// SPDX-License-Identifier: MPL-2.0
//! GetTagData: the data of the first item with a given tag, or a default,
//! as `FindTagItem` and a fallback.

const sdk = @import("sdk");

const UtilityBase = @import("../utility.zig").UtilityBase;
const Tag = sdk.utility.Tag;
const TagItem = sdk.utility.TagItem;

/// Returns the data of the first item with a given tag, or a default.
///
/// SYNOPSIS:
/// ```zig
/// fn GetTagData(ub: *UtilityBase, tag_val: Tag, default_value: usize, tag_list: ?[*]const TagItem) usize
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `tag_val` - the tag to look for.
/// - `default_value` - what to return when the list does not have the tag.
/// - `tag_list` - the list. Null is an empty list.
///
/// RESULT:
/// The first matching item's `ti_Data`, or `default_value`.
///
/// BEHAVIOR:
/// `FindTagItem` with a fallback, for the common case of an option with a
/// default. A tag given with the default as its data cannot be told from a
/// missing one; `FindTagItem` tells them apart.
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
/// `FindTagItem`, `NextTagItem`
///
/// EXAMPLES:
/// ```zig
/// const stack_size = ub.GetTagData(NP_StackSize, 4096, tags);
/// ```
pub fn GetTagData(ub: *UtilityBase, tag_val: Tag, default_value: usize, tag_list: ?[*]const TagItem) usize {
    const utility = ub.iface();
    const item = utility.FindTagItem(tag_val, tag_list) orelse return default_value;
    return item.data;
}
