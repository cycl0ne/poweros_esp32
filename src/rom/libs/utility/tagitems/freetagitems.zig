// SPDX-License-Identifier: MPL-2.0
//! FreeTagItems: gives back an array from `AllocateTagItems` or
//! `CloneTagItems`.

const sdk = @import("sdk");

const UtilityBase = @import("../utility.zig").UtilityBase;
const TagItem = sdk.utility.TagItem;

/// Gives back an array from `AllocateTagItems` or `CloneTagItems`.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeTagItems(ub: *UtilityBase, tag_list: ?[*]TagItem) void
/// ```
///
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// - `tag_list` - the array. Null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// `FreeVec` on the array, which finds the size in front of it. Only the
/// array goes; whatever its items point to is left alone.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. `FreeMem` takes Forbid.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The array is gone, with everything that pointed into it.
///
/// NOTES:
/// An array from anywhere else - a constant list, one on the stack - must
/// not be passed: the size word `FreeVec` reads is not there.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocateTagItems`, `CloneTagItems`
///
/// EXAMPLES:
/// ```zig
/// ub.FreeTagItems(copy);
/// ```
pub fn FreeTagItems(ub: *UtilityBase, tag_list: ?[*]TagItem) void {
    ub.sys_base.FreeVec(@ptrCast(tag_list));
}
