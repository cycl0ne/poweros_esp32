// SPDX-License-Identifier: MPL-2.0
//! DamageLayer: adds an area to a layer's damage. What uncovering takes
//! from a layer this library works out itself; what something other than
//! the layer's program paints over, only the painter knows, and this is
//! how it says so.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const Layer = _layerinfo.Layer;
const tile = @import("../tile/_tile.zig");
const _locks = @import("../locks/_locks.zig");
const LayersBase = @import("../layers.zig").LayersBase;

/// Says that part of a layer has to be drawn again.
///
/// SYNOPSIS:
/// ```zig
/// fn DamageLayer(lb: *LayersBase, layer: *Layer, area: *const graphics.Rect) bool
/// ```
///
/// SINCE: 0.4. LVO -120.
///
/// INPUTS:
/// - `layer` - the layer.
/// - `area` - what has to be drawn again, in the **layer's** coordinates.
///
/// RESULT:
/// True, or false with `LERR_NO_MEMORY` in the layer if there was no
/// memory to add it.
///
/// BEHAVIOR:
/// The area is cut to the layer and joins its damage, and the layer is
/// owed a refresh (`LAYERREFRESH`) - what `BeginUpdate` then narrows it to.
/// On a simple layer the area is cut to what of the layer can be seen as
/// well: a covered part keeps nothing, and becomes damage of its own when
/// it is uncovered. A smart layer keeps its covered parts, so there they
/// stay in the damage, to be drawn into what is kept. Nothing is painted:
/// what is on the display in the area stays until it is drawn again.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the layer.
/// - Interrupts: no. It may wait.
/// - Locks: no spinlock may be held: it waits for a lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `area` stays the caller's and is only read.
///
/// NOTES:
/// - Called between the caller's own `BeginUpdate` and `EndUpdate`, the
///   area is not part of what that update draws, and an `EndUpdate` that
///   says it is done clears it with the rest. Damage a layer after its
///   update.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BeginUpdate`, `EndUpdate`, `GetLayerAttrs` (`LATAG_GetDamage`)
///
/// EXAMPLES:
/// ```zig
/// // Where the old right border was is inside the window now, painted
/// // over: its program draws it again on the refresh this asks for.
/// _ = lb.DamageLayer(layer, &.{ .min_x = old_width - border, .min_y = top, .max_x = old_width, .max_y = bottom });
/// ```
pub fn DamageLayer(lb: *LayersBase, layer: *Layer, area: *const graphics.Rect) bool {
    _locks.holdOne(lb, layer);
    defer _locks.releaseOne(lb, layer);
    const own = graphics.Rect{ .max_x = layer.bounds.width(), .max_y = layer.bounds.height() };
    const cut = graphics.Rect.intersect(area.*, own);
    if (cut.isEmpty()) return true;
    if (!lb.graphics_base.OrRectRegion(layer.damage, &cut)) {
        layer.last_error = layers.LERR_NO_MEMORY;
        return false;
    }
    layer.flags |= layers.LAYERREFRESH;
    if (layer.flags & (layers.LAYERSMART | layers.LAYERSUPER) == 0) tile.trimDamage(lb, layer);
    layer.last_error = layers.LERR_OK;
    return true;
}
