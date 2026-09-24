// SPDX-License-Identifier: MPL-2.0
//! XorRectRegion: what is in the region or the rectangle, but not in both.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const Rect = graphics.Rect;
const Region = _region.Region;
const _region = @import("_region.zig");

/// What is in the region or the rectangle, but not in both.
///
/// SYNOPSIS:
/// ```zig
/// fn XorRectRegion(gb: *GraphicsBase, region: *Region, rect: *const Rect) bool
/// ```
///
/// SINCE: 0.8. LVO -232.
///
/// INPUTS:
/// - `region` - the region to change.
/// - `rect` - the rectangle.
///
/// RESULT:
/// False without memory for the rectangles.
///
/// BEHAVIOR:
/// The answer is built in a copy of the region: the part of the rectangle
/// the region does not already cover is worked out in a region of its
/// own, then the copy loses what the rectangle covers and gains that part.
/// Only a complete answer replaces the region, so a failure leaves it as
/// it was.
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
/// `XorRegionRegion`, `OrRectRegion`, `ClearRectRegion`
///
/// EXAMPLES:
/// ```zig
/// _ = gb.XorRectRegion(region, &toggled);
/// ```
pub fn XorRectRegion(gb: *GraphicsBase, region: *Region, rect: *const Rect) bool {
    const graphics_lib = gb.iface();
    if (rect.isEmpty()) return true;
    // The part of the rectangle the region does not already cover has to be
    // worked out before the region is changed, so it is done in a region of
    // its own: the rectangle, less everything the region holds.
    var only_rect = Region{};
    // The answer is built beside the region and swapped in whole, so a
    // failure part way leaves the region untouched.
    var built = Region{};
    const ok = xorInto(gb, region, rect, &only_rect, &built);
    graphics_lib.ClearRegion(@ptrCast(&only_rect));
    if (!ok) {
        graphics_lib.ClearRegion(@ptrCast(&built));
        return false;
    }
    graphics_lib.ClearRegion(@ptrCast(region));
    region.* = built;
    return true;
}

/// The region with the rectangle toggled, into `built`; the region itself
/// is only read. False without memory, with whatever was made left in
/// `only_rect` and `built` for the caller to clear.
fn xorInto(gb: *GraphicsBase, region: *const Region, rect: *const Rect, only_rect: *Region, built: *Region) bool {
    const graphics_lib = gb.iface();
    if (!graphics_lib.OrRectRegion(@ptrCast(only_rect), rect)) return false;
    var at = region.head;
    while (at) |r| : (at = r.next) {
        if (!graphics_lib.ClearRectRegion(@ptrCast(only_rect), &r.bounds)) return false;
    }
    // The copy loses what the rectangle covers, and gains the rest.
    if (!graphics_lib.OrRegionRegion(@ptrCast(region), @ptrCast(built))) return false;
    if (!graphics_lib.ClearRectRegion(@ptrCast(built), rect)) return false;
    return graphics_lib.OrRegionRegion(@ptrCast(only_rect), @ptrCast(built));
}
