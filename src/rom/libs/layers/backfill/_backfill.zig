// SPDX-License-Identifier: MPL-2.0
//! Painting a part of a layer that has nothing in it yet.
//!
//! A layer that has just been made has never drawn anything, and what is
//! on the display where it now is belongs to whatever was there before. A
//! layer that has just been made bigger has the same problem over the part
//! it gained. Left alone, the new area shows somebody else's pixels until
//! the program gets round to drawing, which is the one thing a window
//! system must not do.
//!
//! So the area is **backfilled**. What with is the layer's business:
//!
//! - nothing said - the layer's own background pen, which is black unless
//!   the program set another;
//! - `LAYERS_NOBACKFILL` - left exactly as it is, for a layer that is
//!   about to draw all of itself anyway and would rather not pay twice;
//! - a `Hook` - called once per rectangle with the layer's RastPort and a
//!   `BackFillMsg`, so a program can put a pattern or a picture there.
//!
//! It is drawn **through the layer's own RastPort**, which is what makes
//! this short: the clip targets are already in place, so the paint lands
//! on the display where the layer can be seen and in the layer's keeping
//! where it cannot, and a hook writing into a covered layer works without
//! knowing that it is covered.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;
const utility = sdk.utility;
const Rect = graphics.Rect;
const TagItem = sdk.utility.TagItem;

const info_mod = @import("../layerinfo/_layerinfo.zig");
const Layer = info_mod.Layer;
const LayersBase = @import("../layers.zig").LayersBase;

/// Paint `area`, in the layer's own coordinates.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer.
/// - `area` - what to paint.
pub fn fill(lb: *LayersBase, layer: *Layer, area: Rect) void {
    if (area.isEmpty()) return;
    // The layer's RastPort carries the hook, so this is graphics.library's
    // `EraseRect` doing the whole of it: the hook when there is one, the
    // layer's own background pen when there is not, nothing when the layer
    // asked for nothing. What a hook is told - which layer, which piece -
    // wants the layer named, which `EraseRect` cannot know, so it is filled
    // in here and the RastPort's own answer is only used for the rest.
    if (layer.backfill == layers.LAYERS_NOBACKFILL) return;
    if (layer.backfill != 0) {
        const hook: *utility.Hook = @ptrFromInt(layer.backfill);
        var msg = layers.BackFillMsg{ .layer = @ptrCast(layer), .area = area };
        _ = lb.utility_base.CallHookPkt(hook, layer.rp, &msg);
        return;
    }
    lb.graphics_base.EraseRect(layer.rp, &area);
}

/// Paint every rectangle of a region, in the layer's own coordinates.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer.
/// - `region` - what to paint.
pub fn fillRegion(lb: *LayersBase, layer: *Layer, region: *graphics.Region) void {
    if (layer.backfill == layers.LAYERS_NOBACKFILL) return;
    const gb = lb.graphics_base;
    const info = layer.info;
    const n = gb.RegionRectangles(region, null, 0);
    if (n == 0) return;
    const bytes = n * @sizeOf(Rect);
    const mem = lb.sys_base.AllocPooled(info.pool, bytes) orelse return;
    defer lb.sys_base.FreePooled(info.pool, mem, bytes);
    const rects: [*]Rect = @ptrCast(@alignCast(mem));
    _ = gb.RegionRectangles(region, rects, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) fill(lb, layer, rects[i]);
}
