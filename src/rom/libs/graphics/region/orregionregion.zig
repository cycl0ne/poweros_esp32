// SPDX-License-Identifier: MPL-2.0
//! OrRegionRegion: adds everything in `source` to `dest`.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const Region = _region.Region;
const _region = @import("_region.zig");

/// Adds everything in `source` to `dest`.
///
/// SYNOPSIS:
/// ```zig
/// fn OrRegionRegion(gb: *GraphicsBase, source: *const Region, dest: *Region) bool
/// ```
///
/// SINCE: 0.8. LVO -236.
///
/// INPUTS:
/// - `source` - the region to add. Read and not changed.
/// - `dest` - the region that grows.
///
/// RESULT:
/// False without memory for the rectangles; `dest` may then hold part of
/// `source`.
///
/// BEHAVIOR:
/// Each rectangle of `source` is added as `OrRectRegion` would add it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. Rectangles come from the region pool.
/// - Forbid: not needed; the region is the caller's to keep others off.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `dest` keeps its rectangles in the region pool; `source` is untouched.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OrRectRegion`, `AndRegionRegion`
///
/// EXAMPLES:
/// ```zig
/// _ = gb.OrRegionRegion(damage, total);
/// ```
pub fn OrRegionRegion(gb: *GraphicsBase, source: *const Region, dest: *Region) bool {
    const graphics_lib = gb.iface();
    var at = source.head;
    while (at) |r| : (at = r.next) {
        if (!graphics_lib.OrRectRegion(@ptrCast(dest), &r.bounds)) return false;
    }
    return true;
}
