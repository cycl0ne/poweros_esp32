// SPDX-License-Identifier: MPL-2.0
//! ClearRegion: empties a region, keeping the region itself.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const freeList = _region.freeList;
const Region = _region.Region;
const _region = @import("_region.zig");

/// Empties a region, keeping the region itself.
///
/// SYNOPSIS:
/// ```zig
/// fn ClearRegion(gb: *GraphicsBase, region: *Region) void
/// ```
///
/// SINCE: 0.8. LVO -208.
///
/// INPUTS:
/// - `region` - the region.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Every rectangle goes back to the pool and the bounds become empty, so
/// the region can be filled again without a new one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It frees memory.
/// - Forbid: not needed; the region is the caller's to keep others off.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The rectangles are gone; the region stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DisposeRegion`, `NewRegion`
///
/// EXAMPLES:
/// ```zig
/// gb.ClearRegion(region);
/// ```
pub fn ClearRegion(gb: *GraphicsBase, region: *Region) void {
    freeList(gb, region.head);
    region.head = null;
    region.bounds = .{};
}
