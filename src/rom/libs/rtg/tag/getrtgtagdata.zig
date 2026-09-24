// SPDX-License-Identifier: MPL-2.0
//! GetRtgTagData: A tag's data, or `default_value` if it is not in the
//! list.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;

/// Returns a tag's data from a list, or a default.
///
/// SYNOPSIS:
/// ```zig
/// fn GetRtgTagData(rb: *RtgBase, tag_value: Tag, default_value: usize, tag_list: ?[*]const TagItem) usize
/// ```
///
/// SINCE: 1.0. LVO -192.
///
/// INPUTS:
/// - `tag_value` - the tag.
/// - `default_value` - what to answer when the list does not have it.
/// - `tag_list` - the list.
///
/// RESULT:
/// The first matching item's data, or `default_value`.
///
/// BEHAVIOR:
/// utility.library's `GetTagData`, here so a driver need open nothing but
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
/// `FindRtgTagItem`
///
/// EXAMPLES:
/// ```zig
/// const hz = rb.GetRtgTagData(MY_Clock, 12_000_000, tags);
/// ```
pub fn GetRtgTagData(rb: *RtgBase, tag_value: Tag, default_value: usize, tag_list: ?[*]const TagItem) usize {
    return rb.utility_base.GetTagData(tag_value, default_value, tag_list);
}
