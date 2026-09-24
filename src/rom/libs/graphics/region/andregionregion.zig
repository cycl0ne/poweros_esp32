// SPDX-License-Identifier: MPL-2.0
//! AndRegionRegion: cuts `dest` down to what is also in `source`.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _region = @import("_region.zig");
const Rect = graphics.Rect;
const Region = _region.Region;

/// Cuts `dest` down to what is also in `source`.
///
/// SYNOPSIS:
/// ```zig
/// fn AndRegionRegion(gb: *GraphicsBase, source: *const Region, dest: *Region) bool
/// ```
///
/// SINCE: 0.8. LVO -240.
///
/// INPUTS:
/// - `source` - the region to keep inside. Read and not changed.
/// - `dest` - the region that is cut down.
///
/// RESULT:
/// False without memory for the rectangles; `dest` is then as it was.
///
/// BEHAVIOR:
/// Each rectangle of `dest` is kept where it meets a rectangle of
/// `source`. The answer is built beside `dest` and swapped in at the end, so
/// no rectangle of `source` can undo what another added.
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
/// `AndRectRegion`, `SubRegionRegion`
///
/// EXAMPLES:
/// ```zig
/// _ = gb.AndRegionRegion(clip, visible);
/// ```
pub fn AndRegionRegion(gb: *GraphicsBase, source: *const Region, dest: *Region) bool {
    const graphics_lib = gb.iface();
    // Each rectangle of dest is kept only where it meets some rectangle of
    // source, so the answer is built rather than cut: one pass, and no
    // rectangle of source can undo what another added.
    var built = Region{};
    var mine = dest.head;
    while (mine) |d| : (mine = d.next) {
        var theirs = source.head;
        while (theirs) |s| : (theirs = s.next) {
            const meet = Rect.intersect(d.bounds, s.bounds);
            if (meet.isEmpty()) continue;
            if (!graphics_lib.OrRectRegion(@ptrCast(&built), &meet)) {
                graphics_lib.ClearRegion(@ptrCast(&built));
                return false;
            }
        }
    }
    graphics_lib.ClearRegion(@ptrCast(dest));
    dest.* = built;
    return true;
}
