// SPDX-License-Identifier: MPL-2.0
//! RegionRectangles: what is in one of the two but not in both.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _region = @import("_region.zig");
const Rect = graphics.Rect;
const Region = _region.Region;
const before = _region.before;

/// Reads out the rectangles a region is made of.
///
/// SYNOPSIS:
/// ```zig
/// fn RegionRectangles(_: *GraphicsBase, region: *const Region, into: ?[*]Rect, max: u32) u32
/// ```
///
/// SINCE: 0.8. LVO -252.
///
/// INPUTS:
/// - `region` - the region.
/// - `into` - where to write them, or null to only count.
/// - `max` - how many `into` has room for.
///
/// RESULT:
/// How many rectangles the region has, whatever `max` was. Up to `max` of
/// them are written. 0 means the region is empty.
///
/// BEHAVIOR:
/// They do not overlap - that is the invariant a region keeps - and they
/// are in order of `min_y`, then `min_x`. The order matters to a caller
/// moving pixels over the surface they are already on, which has to work
/// through them in the order they lie in to read before it writes.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself: it only reads the region.
/// - Forbid: not needed; the region is the caller's to keep others off.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The rectangles are copied into the caller's room.
///
/// NOTES:
/// This is how anything outside this library sees the shape of a region,
/// which is otherwise opaque. Asking with `into` null and `max` 0 is how
/// to find out how much room is needed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NewRegion`, `PointInRegion`
///
/// EXAMPLES:
/// ```zig
/// const n = gb.RegionRectangles(region, null, 0);
/// // ... room for n ...
/// _ = gb.RegionRectangles(region, buffer.ptr, n);
/// ```
pub fn RegionRectangles(_: *GraphicsBase, region: *const Region, into: ?[*]Rect, max: u32) u32 {
    var count: u32 = 0;
    var at = region.head;
    while (at) |r| : (at = r.next) {
        // Insertion sort into what has been kept so far. Every rectangle
        // is offered, not only the first `max` of them: a caller with room
        // for one wants the first in order, not whichever happened to be
        // at the head of the list, and the order is what is promised.
        if (into) |out| {
            if (max != 0) {
                const kept = @min(count, max);
                if (kept < max or before(r.bounds, out[max - 1])) {
                    var i = @min(kept, max - 1);
                    while (i > 0 and before(r.bounds, out[i - 1])) : (i -= 1) out[i] = out[i - 1];
                    out[i] = r.bounds;
                }
            }
        }
        count += 1;
    }
    return count;
}
