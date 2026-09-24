// SPDX-License-Identifier: MPL-2.0
//! AllocateTagItems: a cleared array of tag items from `AllocVec`, for
//! `FreeTagItems` to give back.

const sdk = @import("sdk");
const exec = sdk.exec;

const UtilityBase = @import("../utility.zig").UtilityBase;
const TagItem = sdk.utility.TagItem;

/// Allocates an array of tag items, cleared.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocateTagItems(ub: *UtilityBase, num_tags: u32) ?[*]TagItem
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `num_tags` - how many items. The `TAG_DONE` that ends a list is one of
///   them. 0 gives null.
///
/// RESULT:
/// The array, or null for 0 items or without memory.
///
/// BEHAVIOR:
/// Every item is `{ TAG_DONE, 0 }`, so the array is an empty list at every
/// position until it is filled. It comes from `AllocVec`, which is what
/// lets `FreeTagItems` give it back by its address alone.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It allocates, and `AllocMem` takes Forbid.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller owns the array and gives it back with `FreeTagItems`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeTagItems`, `CloneTagItems`
///
/// EXAMPLES:
/// ```zig
/// const tags = ub.AllocateTagItems(3) orelse return error.NoMemory;
/// defer ub.FreeTagItems(tags);
/// ```
pub fn AllocateTagItems(ub: *UtilityBase, num_tags: u32) ?[*]TagItem {
    // A count whose byte size does not fit is memory there cannot be.
    const bytes, const overflow = @mulWithOverflow(@as(usize, num_tags), @sizeOf(TagItem));
    if (overflow != 0) return null;
    const block = ub.sys_base.AllocVec(bytes, exec.MEMF_CLEAR) orelse return null;
    return @ptrCast(@alignCast(block));
}
