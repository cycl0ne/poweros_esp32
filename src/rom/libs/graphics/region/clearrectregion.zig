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
/// region call rests on. A rectangle it does not meet stays as it is, so
/// the call costs what it cuts, not what the region holds; and nothing
/// changes until every piece has been had, so a call that runs out of
/// memory leaves the region as it was.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. Rectangles come from the region pool.
/// - Locks: none taken; keeping others off the region is the caller's.
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

    // The pieces of every rectangle the hole meets, all of them had
    // before anything changes.
    var pieces: ?*RegionRect = null;
    var at = region.head;
    while (at) |r| : (at = r.next) {
        if (Rect.intersect(r.bounds, hole).isEmpty()) continue;
        if (!cutOut(gb, r.bounds, hole, &pieces)) {
            freeList(gb, pieces);
            return false;
        }
    }
    // Then the rectangles it meets go and the others stay, with the
    // pieces after them.
    var kept: ?*RegionRect = null;
    at = region.head;
    while (at) |r| {
        const next = r.next;
        if (Rect.intersect(r.bounds, hole).isEmpty()) {
            r.next = kept;
            kept = r;
        } else {
            gb.sys_base.FreePooled(gb.region_pool, r, @sizeOf(RegionRect));
        }
        at = next;
    }
    while (pieces) |p| {
        pieces = p.next;
        p.next = kept;
        kept = p;
    }
    region.head = kept;
    refreshBounds(region);
    return true;
}
