// SPDX-License-Identifier: MPL-2.0
//! OffsetRegion: moves a whole region.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _region = @import("_region.zig");
const Region = _region.Region;

/// Moves a whole region.
///
/// SYNOPSIS:
/// ```zig
/// fn OffsetRegion(_: *GraphicsBase, region: *Region, dx: i32, dy: i32) void
/// ```
///
/// SINCE: 0.8. LVO -216.
///
/// INPUTS:
/// - `region` - the region.
/// - `dx` - how far across.
/// - `dy` - how far down.
///
/// RESULT:
/// Nothing. It cannot fail.
///
/// BEHAVIOR:
/// Every rectangle moves, since they are kept in absolute coordinates.
/// Keeping them relative to the region's bounds would make this free and
/// cost an addition in each of the other twelve calls; the region is
/// opaque, so that trade can be made again later without anything noticing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
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
/// gb.OffsetRegion(region, -layer_x, -layer_y);
/// ```
pub fn OffsetRegion(_: *GraphicsBase, region: *Region, dx: i32, dy: i32) void {
    var at = region.head;
    while (at) |r| : (at = r.next) {
        r.bounds.min_x += dx;
        r.bounds.min_y += dy;
        r.bounds.max_x += dx;
        r.bounds.max_y += dy;
    }
    if (region.head != null) {
        region.bounds.min_x += dx;
        region.bounds.min_y += dy;
        region.bounds.max_x += dx;
        region.bounds.max_y += dy;
    }
}
