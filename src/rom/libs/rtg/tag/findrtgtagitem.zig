// SPDX-License-Identifier: MPL-2.0
//! FindRtgTagItem: The tag of that value in the list, or null.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;

/// Finds a tag in a list.
///
/// SYNOPSIS:
/// ```zig
/// fn FindRtgTagItem(rb: *RtgBase, tag_value: Tag, tag_list: ?[*]const TagItem) ?*const TagItem
/// ```
///
/// SINCE: 1.0. LVO -196.
///
/// INPUTS:
/// - `tag_value` - the tag.
/// - `tag_list` - the list; `TAG_MORE` is followed.
///
/// RESULT:
/// The item, or null.
///
/// BEHAVIOR:
/// utility.library's `FindTagItem`, here so a driver need open nothing but
/// this library.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself: it reads the list.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetRtgTagData`
///
/// EXAMPLES:
/// ```zig
/// if (rb.FindRtgTagItem(MY_Mirror, tags) != null) mirror = true;
/// ```
pub fn FindRtgTagItem(rb: *RtgBase, tag_value: Tag, tag_list: ?[*]const TagItem) ?*const TagItem {
    return rb.utility_base.FindTagItem(tag_value, tag_list);
}
