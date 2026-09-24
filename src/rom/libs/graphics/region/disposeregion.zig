// SPDX-License-Identifier: MPL-2.0
//! DisposeRegion: gives a region back, with every rectangle in it.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _region = @import("_region.zig");
const Region = _region.Region;
const freeList = _region.freeList;

/// Gives a region back, with every rectangle in it.
///
/// SYNOPSIS:
/// ```zig
/// fn DisposeRegion(gb: *GraphicsBase, region: ?*Region) void
/// ```
///
/// SINCE: 0.8. LVO -204.
///
/// INPUTS:
/// - `region` - the region. Null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Every rectangle goes back to the region pool, then the region itself.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It frees memory.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The region and its rectangles are gone.
///
/// NOTES:
/// - A RastPort still using it as its clip region must be given another
///   clip first, or it will be reading freed memory.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NewRegion`, `ClearRegion`
///
/// EXAMPLES:
/// ```zig
/// gb.DisposeRegion(region);
/// ```
pub fn DisposeRegion(gb: *GraphicsBase, region: ?*Region) void {
    const r = region orelse return;
    freeList(gb, r.head);
    gb.sys_base.FreeVec(r);
}
