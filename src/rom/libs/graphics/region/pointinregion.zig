// SPDX-License-Identifier: MPL-2.0
//! PointInRegion: whether a point is inside a region.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _region = @import("_region.zig");
const Region = _region.Region;

/// Whether a point is inside a region.
///
/// SYNOPSIS:
/// ```zig
/// fn PointInRegion(_: *GraphicsBase, region: *const Region, x: i32, y: i32) bool
/// ```
///
/// SINCE: 0.8. LVO -212.
///
/// INPUTS:
/// - `region` - the region.
/// - `x` - the point's column.
/// - `y` - its row.
///
/// RESULT:
/// True if the point is in any of the region's rectangles. The region's
/// own bounds are checked first, so a point nowhere near it costs two
/// comparisons rather than a walk.
///
/// BEHAVIOR:
/// A rectangle holds its minimum edges and not its maximum ones, as every
/// rectangle here does.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself: it only reads the region.
/// - Forbid: not needed; the region is the caller's to keep others off.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NewRegion`, `DisposeRegion`, `RegionRectangles`
///
/// EXAMPLES:
/// ```zig
/// if (gb.PointInRegion(region, mouse_x, mouse_y)) hit();
/// ```
pub fn PointInRegion(_: *GraphicsBase, region: *const Region, x: i32, y: i32) bool {
    if (x < region.bounds.min_x or x >= region.bounds.max_x) return false;
    if (y < region.bounds.min_y or y >= region.bounds.max_y) return false;
    var at = region.head;
    while (at) |r| : (at = r.next) {
        const b = r.bounds;
        if (x >= b.min_x and x < b.max_x and y >= b.min_y and y < b.max_y) return true;
    }
    return false;
}
