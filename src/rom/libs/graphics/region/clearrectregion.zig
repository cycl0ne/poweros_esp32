// SPDX-License-Identifier: MPL-2.0
//! ClearRectRegion: takes a rectangle out of a region.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const refreshBounds = _region.refreshBounds;
const freeList = _region.freeList;
const cutOut = _region.cutOut;
const RegionRect = _region.RegionRect;
const Rect = graphics.Rect;
const Region = _region.Region;
const _region = @import("_region.zig");

/// Takes a rectangle out of a region.
///
/// SYNOPSIS:
/// ```zig
/// fn ClearRectRegion(gb: *GraphicsBase, region: *Region, rect: *const Rect) bool
/// ```
///
/// SINCE: 0.8. LVO -228.
///
/// INPUTS:
/// - `region` - the region to change.
/// - `rect` - the rectangle to take out. An empty one takes nothing.
///
/// RESULT:
/// False if a rectangle could not be allocated. The region is then as it
/// was: the new list is built beside the old one and only swapped in when
/// all of it succeeded.
///
/// BEHAVIOR:
/// Every rectangle of the region that meets it is cut into the up to four
/// pieces that lie around it. This one cut is the geometry every other
/// region call rests on.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. Rectangles come from the region pool.
/// - Forbid: not needed; the region is the caller's to keep others off.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The region keeps its rectangles in the region pool.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SubRegionRegion`, `OrRectRegion`
///
/// EXAMPLES:
/// ```zig
/// _ = gb.ClearRectRegion(visible, &covering_window);
/// ```
pub fn ClearRectRegion(gb: *GraphicsBase, region: *Region, rect: *const Rect) bool {
    const hole = rect.*;
    if (hole.isEmpty()) return true;
    if (Rect.intersect(region.bounds, hole).isEmpty()) return true;

    var built: ?*RegionRect = null;
    var at = region.head;
    while (at) |r| : (at = r.next) {
        if (!cutOut(gb, r.bounds, hole, &built)) {
            freeList(gb, built);
            return false;
        }
    }
    freeList(gb, region.head);
    region.head = built;
    refreshBounds(region);
    return true;
}
