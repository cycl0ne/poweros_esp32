// SPDX-License-Identifier: MPL-2.0
//! XorRegionRegion: xorRegionRegion

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _region = @import("_region.zig");
const Region = _region.Region;

/// Leaves in `dest` what is in one of the two regions but not in both.
///
/// SYNOPSIS:
/// ```zig
/// fn XorRegionRegion(gb: *GraphicsBase, source: *const Region, dest: *Region) bool
/// ```
///
/// SINCE: 0.8. LVO -248.
///
/// INPUTS:
/// - `source` - the other region. Read and not changed.
/// - `dest` - the region that changes.
///
/// RESULT:
/// False without memory for the rectangles.
///
/// BEHAVIOR:
/// Each rectangle of `source` is applied as `XorRectRegion` would apply it,
/// to a copy of `dest`; only a complete answer replaces `dest`, so a
/// failure leaves it as it was.
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
/// `XorRectRegion`, `OrRegionRegion`
///
/// EXAMPLES:
/// ```zig
/// _ = gb.XorRegionRegion(before, after); // what changed
/// ```
pub fn XorRegionRegion(gb: *GraphicsBase, source: *const Region, dest: *Region) bool {
    const graphics_lib = gb.iface();
    // Worked on a copy and swapped in whole, so a failure part way leaves
    // `dest` as it was.
    var built = Region{};
    if (!graphics_lib.OrRegionRegion(@ptrCast(dest), @ptrCast(&built))) {
        graphics_lib.ClearRegion(@ptrCast(&built));
        return false;
    }
    var at = source.head;
    while (at) |r| : (at = r.next) {
        if (!graphics_lib.XorRectRegion(@ptrCast(&built), &r.bounds)) {
            graphics_lib.ClearRegion(@ptrCast(&built));
            return false;
        }
    }
    graphics_lib.ClearRegion(@ptrCast(dest));
    dest.* = built;
    return true;
}
