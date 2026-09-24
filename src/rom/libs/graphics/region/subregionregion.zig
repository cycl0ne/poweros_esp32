// SPDX-License-Identifier: MPL-2.0
//! SubRegionRegion: takes everything in `source` out of `dest`.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _region = @import("_region.zig");
const Region = _region.Region;

/// Takes everything in `source` out of `dest`.
///
/// SYNOPSIS:
/// ```zig
/// fn SubRegionRegion(gb: *GraphicsBase, source: *const Region, dest: *Region) bool
/// ```
///
/// SINCE: 0.8. LVO -244.
///
/// INPUTS:
/// - `source` - what to take out. Read and not changed.
/// - `dest` - the region that loses it.
///
/// RESULT:
/// False without memory for the rectangles; `dest` may then have lost
/// part of `source`.
///
/// BEHAVIOR:
/// Each rectangle of `source` is taken out as `ClearRectRegion` would.
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
/// NOTES:
/// - This is what a window covered by another is left with.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ClearRectRegion`, `AndRegionRegion`
///
/// EXAMPLES:
/// ```zig
/// _ = gb.SubRegionRegion(in_front, visible);
/// ```
pub fn SubRegionRegion(gb: *GraphicsBase, source: *const Region, dest: *Region) bool {
    const graphics_lib = gb.iface();
    var at = source.head;
    while (at) |r| : (at = r.next) {
        if (!graphics_lib.ClearRectRegion(@ptrCast(dest), &r.bounds)) return false;
    }
    return true;
}
