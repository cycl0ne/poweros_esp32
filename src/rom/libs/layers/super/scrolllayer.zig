// SPDX-License-Identifier: MPL-2.0
//! ScrollLayer: moves the window a `LAYERSUPER` layer shows of its own
//! bitmap.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const _super = @import("_super.zig");
const tile = @import("../tile/_tile.zig");
const _locks = @import("../locks/_locks.zig");
const LayersBase = @import("../layers.zig").LayersBase;

/// Moves the window a `LAYERSUPER` layer shows of its own bitmap.
///
/// SYNOPSIS:
/// ```zig
/// fn ScrollLayer(lb: *LayersBase, layer: *Layer, dx: i32, dy: i32) bool
/// ```
///
/// SINCE: 0.1. LVO -104.
///
/// INPUTS:
/// - `layer` - a layer made with `LAYERSUPER`.
/// - `dx` - how far across the bitmap; positive shows more of the right.
/// - `dy` - how far down; positive shows more of the bottom.
///
/// RESULT:
/// True, or false with the reason in the layer: `LERR_NO_SUPERBITMAP` for a
/// layer without a bitmap of its own, `LERR_NO_MEMORY` if the clipping
/// could not be worked out. Scrolling past the bitmap's edge stops at it,
/// which is not a failure.
///
/// BEHAVIOR:
/// What is on the display is put back into the bitmap first: while a part
/// of the layer is visible its pixels are on the display and the bitmap
/// does not have them, so scrolling without that would lose whatever was
/// drawn while it showed. Then the window moves, and the part it has moved
/// on to is copied out of the bitmap.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the layer.
/// - Interrupts: no. It may wait, it allocates, and it draws.
/// - Forbid: must not be held: waiting for the lock would break it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated that outlives the call. The bitmap stays the
/// caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateLayerTagList`, `GetLayerAttrs`
///
/// EXAMPLES:
/// ```zig
/// _ = lb.ScrollLayer(layer, 0, 16);
/// ```
pub fn ScrollLayer(lb: *LayersBase, layer: *Layer, dx: i32, dy: i32) bool {
    _locks.holdOne(lb, layer);
    defer _locks.releaseOne(lb, layer);
    layer.last_error = layers.LERR_OK;
    const bm = layer.super orelse {
        layer.last_error = layers.LERR_NO_SUPERBITMAP;
        return false;
    };
    if (dx == 0 and dy == 0) return true;

    // Held inside the bitmap: scrolling past its edge stops there rather
    // than showing memory that is not its.
    const most_x = @max(0, @as(i32, @intCast(bm.width)) - layer.bounds.width());
    const most_y = @max(0, @as(i32, @intCast(bm.height)) - layer.bounds.height());
    const to_x = @max(0, @min(layer.scroll_x + dx, most_x));
    const to_y = @max(0, @min(layer.scroll_y + dy, most_y));
    if (to_x == layer.scroll_x and to_y == layer.scroll_y) return true;

    // What is on the display belongs in the bitmap before the window moves
    // off it, or everything drawn while it was shown would be lost.
    _super.move(lb, layer, layer.visible, true);
    layer.scroll_x = to_x;
    layer.scroll_y = to_y;
    // And the part the window has moved on to comes out of the bitmap.
    _super.move(lb, layer, layer.visible, false);

    // The targets carry the offset, so they all have to be made again.
    if (!tile.rebuild(lb, layer)) {
        layer.last_error = layers.LERR_NO_MEMORY;
        return false;
    }
    return true;
}
