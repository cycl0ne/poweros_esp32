// SPDX-License-Identifier: MPL-2.0
//! OrRectRegion: adds a rectangle to a region.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const refreshBounds = _region.refreshBounds;
const newRect = _region.newRect;
const Rect = graphics.Rect;
const Region = _region.Region;
const _region = @import("_region.zig");

/// Adds a rectangle to a region.
///
/// SYNOPSIS:
/// ```zig
/// fn OrRectRegion(gb: *GraphicsBase, region: *Region, rect: *const Rect) bool
/// ```
///
/// SINCE: 0.8. LVO -220.
///
/// INPUTS:
/// - `region` - the region to change.
/// - `rect` - the rectangle to add. An empty one adds nothing.
///
/// RESULT:
/// False if a rectangle could not be allocated, and the region is then as
/// it was - the new shape is built beside the old one and only swapped in
/// when all of it succeeded, so a region is never left half changed.
///
/// BEHAVIOR:
/// The rectangle is cut out of everything already there before it is
/// added, so nothing in a region ever overlaps and no tidying pass is
/// needed.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. Rectangles come from the region pool.
/// - Forbid: not needed; the region is the caller's to keep others off.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The region keeps its rectangles in the region pool; `DisposeRegion`
/// gives them back.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OrRegionRegion`, `ClearRectRegion`
///
/// EXAMPLES:
/// ```zig
/// const box = graphics.Rect{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 50 };
/// if (!gb.OrRectRegion(region, &box)) return error.NoMemory;
/// ```
pub fn OrRectRegion(gb: *GraphicsBase, region: *Region, rect: *const Rect) bool {
    const add = rect.*;
    const graphics_lib = gb.iface();
    if (add.isEmpty()) return true;
    if (!graphics_lib.ClearRectRegion(@ptrCast(region), &add)) return false;
    const kept = newRect(gb, add) orelse return false;
    kept.next = region.head;
    region.head = kept;
    refreshBounds(region);
    return true;
}
