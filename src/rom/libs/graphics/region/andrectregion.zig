// SPDX-License-Identifier: MPL-2.0
//! AndRectRegion: cuts a region down to what is also inside a rectangle.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _region = @import("_region.zig");
const Rect = graphics.Rect;
const RegionRect = _region.RegionRect;
const Region = _region.Region;
const newRect = _region.newRect;
const freeList = _region.freeList;
const refreshBounds = _region.refreshBounds;

/// Cuts a region down to what is also inside a rectangle.
///
/// SYNOPSIS:
/// ```zig
/// fn AndRectRegion(gb: *GraphicsBase, region: *Region, rect: *const Rect) bool
/// ```
///
/// SINCE: 0.8. LVO -224.
///
/// INPUTS:
/// - `region` - the region to change.
/// - `rect` - what to keep.
///
/// RESULT:
/// False if a rectangle could not be allocated. The region is then as it
/// was: the new list is built beside the old one and only swapped in when
/// all of it succeeded.
///
/// BEHAVIOR:
/// Each rectangle of the region is cut to the rectangle; what does not meet
/// it goes.
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
/// `AndRegionRegion`, `OrRectRegion`
///
/// EXAMPLES:
/// ```zig
/// _ = gb.AndRectRegion(region, &window_bounds);
/// ```
pub fn AndRectRegion(gb: *GraphicsBase, region: *Region, rect: *const Rect) bool {
    const keep = rect.*;
    var built: ?*RegionRect = null;
    var at = region.head;
    while (at) |r| : (at = r.next) {
        const meet = Rect.intersect(r.bounds, keep);
        if (meet.isEmpty()) continue;
        const kept = newRect(gb, meet) orelse {
            freeList(gb, built);
            return false;
        };
        kept.next = built;
        built = kept;
    }
    freeList(gb, region.head);
    region.head = built;
    refreshBounds(region);
    return true;
}
