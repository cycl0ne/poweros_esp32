// SPDX-License-Identifier: MPL-2.0
//! RefillLayer: a part of a layer painted again by its backfill, for a
//! layer whose backfill paints what its program shows.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const Rect = graphics.Rect;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const Layer = _layerinfo.Layer;
const _locks = @import("../locks/_locks.zig");
const compose = @import("../compose/_compose.zig");
const backfill = @import("_backfill.zig");
const LayersBase = @import("../layers.zig").LayersBase;

/// Paints part of a layer again with its backfill.
///
/// SYNOPSIS:
/// ```zig
/// fn RefillLayer(lb: *LayersBase, layer: *Layer, area: *const graphics.Rect) void
/// ```
///
/// SINCE: 0.13. LVO -136.
///
/// INPUTS:
/// - `layer` - the layer.
/// - `area` - what to paint, in the **layer's** coordinates.
///
/// BEHAVIOR:
/// For a program whose backfill hook paints what it shows - a desktop's
/// ground with its icons on it - and which has changed what the hook
/// paints in `area`. The area is cut to the layer.
///
/// A layer with no buffer (`LATAG_NoBuffer`) is shown again over the
/// area: its hook paints it where it can be seen, and whatever is in front
/// of it - a shadow, a window seen through - is laid over that as always.
/// Any other layer has the hook called through its RastPort, as when it
/// is uncovered: into its buffer when it is composed, which is then
/// shown; on the display where it can be seen when it is not, and into
/// what it keeps of its covered parts when it is a smart one.
///
/// Nothing is painted with `LAYERS_NOBACKFILL`; with no hook, the layer's
/// background pen.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the layer - for a layer with no
///   buffer, any layer of its display.
/// - Interrupts: no. It may wait.
/// - Locks: the layer, or for a layer with no buffer every layer of the
///   display, taken here. Never called from a backfill hook, nor while
///   holding anything such a hook waits for: the hook runs with the
///   layers held, on whichever task shows the layer.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `area` stays the caller's and is only read.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InstallLayerHook`, `DamageLayer`, `CreateLayerTagList` (`LATAG_NoBuffer`)
///
/// EXAMPLES:
/// ```zig
/// // An icon picked: the hook paints it on its plate from now on.
/// lb.RefillLayer(ground, &icon_box);
/// ```
pub fn RefillLayer(lb: *LayersBase, layer: *Layer, area: *const Rect) void {
    if (compose.bare(layer)) {
        const info = layer.info;
        _locks.holdAll(lb, info);
        defer _locks.releaseAll(lb, info);
        const b = layer.bounds;
        const cut = Rect.intersect(area.*, .{ .max_x = b.width(), .max_y = b.height() });
        if (cut.isEmpty()) return;
        compose.show(lb, info, .{ .min_x = cut.min_x + b.min_x, .min_y = cut.min_y + b.min_y, .max_x = cut.max_x + b.min_x, .max_y = cut.max_y + b.min_y });
        return;
    }
    _locks.holdOne(lb, layer);
    defer _locks.releaseOne(lb, layer);
    const b = layer.bounds;
    backfill.fill(lb, layer, Rect.intersect(area.*, .{ .max_x = b.width(), .max_y = b.height() }));
}
