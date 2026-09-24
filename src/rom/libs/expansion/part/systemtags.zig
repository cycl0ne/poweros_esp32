// SPDX-License-Identifier: MPL-2.0
//! SystemTags: the system tag list the board's ROM carries.

const sdk = @import("sdk");
const utility = sdk.utility;
const ExpansionBase = @import("../expansion_base.zig").ExpansionBase;

/// The root of the system tag list.
///
/// SYNOPSIS:
/// ```zig
/// fn SystemTags(eb: *ExpansionBase) [*]const utility.TagItem
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The list: SYSTAG_Name, the memory, SYSTAG_Console, and a SYSTAG_Part per
/// part. Never null - a ROM with no system tag list answers an empty one.
///
/// BEHAVIOR:
/// It is the list as the board wrote it; the parts in it are the same
/// ones FindBoardPart hands out as BoardParts.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: yes. - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The ROM's; it lives as long as the machine does.
///
/// NOTES:
/// Read it with utility.library's tag calls: an unknown tag is passed over.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindBoardPart`, sdk/libs/expansion/systemtags.zig
///
/// EXAMPLES:
/// ```zig
/// const name: [*:0]const u8 = @ptrFromInt(ub.GetTagData(st.SYSTAG_Name, @intFromPtr("?"), eb.SystemTags()));
/// ```
pub fn SystemTags(eb: *ExpansionBase) [*]const utility.TagItem {
    return eb.system;
}
