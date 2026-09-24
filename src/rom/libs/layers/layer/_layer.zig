// SPDX-License-Identifier: MPL-2.0
//! What the layer calls share: putting a layer into the order, moving it
//! in the order, and taking it away.
//!
//! A layer owns its RastPort, the two regions it keeps (what it can see
//! and what it owes a redraw) and a lock of its own. Everything that
//! changes what covers what ends in a retile, because the answer for one
//! layer depends on all of them.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const layers = sdk.layers;
const ExecBase = sdk.interface.exec.ExecBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const Rect = graphics.Rect;
const TagItem = sdk.utility.TagItem;

const info_mod = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = info_mod.LayerInfo;
const Layer = info_mod.Layer;
const tile = @import("../tile/_tile.zig");
const smart = @import("../smart/_smart.zig");
const backfill = @import("../backfill/_backfill.zig");
const super = @import("../super/_super.zig");
const rtg = sdk.rtg;
const LayersBase = @import("../layers.zig").LayersBase;

/// Put a layer into the order. A backdrop layer goes behind everything;
/// anything else goes to the front, or behind the other ordinary ones when
/// `behind` is asked for - but still in front of the backdrops, which is
/// what makes them backdrops.
///
/// INPUTS:
/// - `sys` - exec, for the list calls.
/// - `info` - the display.
/// - `layer` - the layer, on no list.
/// - `behind` - behind the ordinary layers rather than in front.
pub fn insert(sys: *ExecBase, info: *LayerInfo, layer: *Layer, behind: bool) void {
    if (layer.flags & layers.LAYERBACKDROP != 0) {
        sys.AddTail(&info.layers, &layer.node);
        return;
    }
    if (!behind) {
        sys.AddHead(&info.layers, &layer.node);
        return;
    }
    var it = info.layers.iterator();
    while (it.next()) |node| {
        const other: *Layer = @fieldParentPtr("node", node);
        if (other.flags & layers.LAYERBACKDROP != 0) {
            sys.Insert(&info.layers, &layer.node, node.pred);
            return;
        }
    }
    sys.AddTail(&info.layers, &layer.node);
}

/// Move a layer in the order and work the tiling out again.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer.
/// - `put` - to the front or to the back.
///
/// RESULT:
/// False, with `LERR_NO_MEMORY` in the layer, if the tiling could not be
/// worked out.
pub fn reorder(lb: *LayersBase, layer: *Layer, put: enum { front, back }) bool {
    const info = layer.info;
    lb.sys_base.Remove(&layer.node);
    insert(lb.sys_base, info, layer, put == .back);
    const ok = tile.retile(lb, info);
    layer.last_error = if (ok) layers.LERR_OK else layers.LERR_NO_MEMORY;
    return ok;
}
