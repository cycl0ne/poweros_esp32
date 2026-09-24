// SPDX-License-Identifier: MPL-2.0
//! FreeBitMap: gives a bitmap back.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _bitmap = @import("_bitmap.zig");
const Surface = rtg.Surface;

/// Gives a bitmap back.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeBitMap(gb: *GraphicsBase, bitmap: ?*Surface) void
/// ```
///
/// SINCE: 0.5. LVO -44.
///
/// INPUTS:
/// - `bitmap` - what `AllocBitMapTagList` returned, or null, which does
///   nothing. A surface this library did not allocate must not be passed:
///   it frees the block the header is the front of.
///
/// RESULT:
/// Nothing. It cannot fail.
///
/// BEHAVIOR:
/// The header and its pixels were one allocation, so one `FreeVec` gives
/// both back.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no; it frees memory.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The header and its pixels, which were one allocation.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocBitMapTagList`
///
/// EXAMPLES:
/// ```zig
/// gb.FreeBitMap(buffer);
/// ```
pub fn FreeBitMap(gb: *GraphicsBase, bitmap: ?*Surface) void {
    const surface = bitmap orelse return;
    // The header is the front of the one block that was allocated, so this
    // is the pointer AllocVec was given.
    gb.sys_base.FreeVec(surface);
}
