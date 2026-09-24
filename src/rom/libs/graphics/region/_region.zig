// SPDX-License-Identifier: MPL-2.0
//! Regions: an area of any shape, held as rectangles that do not overlap.
//!
//! Everything here rests on one primitive - **cut one rectangle out of
//! another**, which leaves up to four pieces: the strip above, the strip
//! below, and what is left to the left and right between them. Every
//! operation is that, repeated:
//!
//! - taking a rectangle out is cutting it out of each rectangle in turn;
//! - adding one is taking it out of everything first, then putting it on
//!   the end - which is what keeps them from overlapping, and is why a
//!   region never needs a pass to tidy itself up;
//! - keeping only what is inside a rectangle is intersecting each and
//!   dropping the empty ones;
//! - the region-against-region operations are those three applied once per
//!   rectangle of the other.
//!
//! So there is one piece of geometry to get right and twelve callers of it.
//!
//! The rectangles are kept in **absolute coordinates**. The reference keeps
//! them relative to the region's own bounds, which makes OffsetRegion free
//! - it moves the bounds and nothing else - at the cost of an addition per
//! rectangle in every other operation, and a chance to forget one. Here the
//! region is opaque, so the choice is invisible and reversible: absolute is
//! taken because there are twelve operations that would pay the addition
//! and one that is made free, and because a region holding a handful of
//! rectangles does not care either way.
//!
//! A region that ends up empty has no rectangles and bounds of all zeroes,
//! so an empty region intersects nothing and contains no point.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const Rect = graphics.Rect;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;

/// One rectangle of a region. They never overlap.
pub const RegionRect = struct {
    bounds: Rect,
    next: ?*RegionRect = null,
};

/// The region itself.
pub const Region = struct {
    /// Every rectangle in it, in no particular order.
    head: ?*RegionRect = null,
    /// The smallest rectangle holding all of them, kept up to date so that
    /// a test against the whole region is one comparison in the common
    /// case. All zeroes when the region is empty.
    bounds: Rect = .{},
};

/// A rectangle from the region pool.
///
/// INPUTS:
/// - `gb` - the library, whose pool it comes from.
/// - `bounds` - what it holds.
///
/// RESULT:
/// The rectangle, on no list, or null without memory.
pub fn newRect(gb: *GraphicsBase, bounds: Rect) ?*RegionRect {
    const mem = gb.sys_base.AllocPooled(gb.region_pool, @sizeOf(RegionRect)) orelse return null;
    const r: *RegionRect = @ptrCast(@alignCast(mem));
    r.* = .{ .bounds = bounds };
    return r;
}

/// Put every rectangle of a list back.
///
/// INPUTS:
/// - `gb` - the library, whose pool they go back to.
/// - `from` - the first rectangle of the list.
pub fn freeList(gb: *GraphicsBase, from: ?*RegionRect) void {
    var at = from;
    while (at) |r| {
        const next = r.next;
        gb.sys_base.FreePooled(gb.region_pool, r, @sizeOf(RegionRect));
        at = next;
    }
}

/// Work out the bounds from the rectangles. Called after anything that can
/// have shrunk the region.
///
/// INPUTS:
/// - `region` - the region.
pub fn refreshBounds(region: *Region) void {
    var at = region.head;
    const first = at orelse {
        region.bounds = .{};
        return;
    };
    var b = first.bounds;
    at = first.next;
    while (at) |r| : (at = r.next) {
        b.min_x = @min(b.min_x, r.bounds.min_x);
        b.min_y = @min(b.min_y, r.bounds.min_y);
        b.max_x = @max(b.max_x, r.bounds.max_x);
        b.max_y = @max(b.max_y, r.bounds.max_y);
    }
    region.bounds = b;
}

/// Cut `hole` out of `whole`, adding what is left to `into`.
///
/// The one piece of geometry in the file. Up to four pieces come out: the
/// strip of `whole` above the hole, the strip below it, and to the left and
/// right of it between those two strips. Cutting it this way rather than
/// into columns is arbitrary but has to be consistent, or two rectangles of
/// one region could come out overlapping.
///
/// RESULT:
/// False if a piece could not be allocated. `into` then holds whatever was
/// added before that, which the caller throws away.
///
/// INPUTS:
/// - `gb` - the library, for the pool.
/// - `whole` - the rectangle being cut.
/// - `hole` - what to take out of it.
/// - `into` - the list the pieces go on.
///
/// RESULT:
/// False without memory.
pub fn cutOut(gb: *GraphicsBase, whole: Rect, hole: Rect, into: *?*RegionRect) bool {
    const meet = Rect.intersect(whole, hole);
    if (meet.isEmpty()) {
        // Nothing was taken out of it, so it survives whole.
        const kept = newRect(gb, whole) orelse return false;
        kept.next = into.*;
        into.* = kept;
        return true;
    }

    const pieces = [_]Rect{
        // Above the hole, full width.
        .{ .min_x = whole.min_x, .min_y = whole.min_y, .max_x = whole.max_x, .max_y = meet.min_y },
        // Below it, full width.
        .{ .min_x = whole.min_x, .min_y = meet.max_y, .max_x = whole.max_x, .max_y = whole.max_y },
        // Left of it, only as tall as the hole.
        .{ .min_x = whole.min_x, .min_y = meet.min_y, .max_x = meet.min_x, .max_y = meet.max_y },
        // And right of it.
        .{ .min_x = meet.max_x, .min_y = meet.min_y, .max_x = whole.max_x, .max_y = meet.max_y },
    };
    for (pieces) |piece| {
        if (piece.isEmpty()) continue;
        const kept = newRect(gb, piece) orelse return false;
        kept.next = into.*;
        into.* = kept;
    }
    return true;
}

/// Whether `a` comes before `b`: higher up, or level and further left.
///
/// INPUTS:
/// - `a` - one rectangle.
/// - `b` - the other.
pub fn before(a: Rect, b: Rect) bool {
    if (a.min_y != b.min_y) return a.min_y < b.min_y;
    return a.min_x < b.min_x;
}
