// SPDX-License-Identifier: MPL-2.0
//! EndUpdate: puts back the clipping `BeginUpdate` narrowed, and clears the
//! damage when all of it was drawn.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const tile = @import("../tile/_tile.zig");
const _locks = @import("../locks/_locks.zig");
const LayersBase = @import("../layers.zig").LayersBase;

/// Puts back what `BeginUpdate` narrowed.
///
/// SYNOPSIS:
/// ```zig
/// fn EndUpdate(lb: *LayersBase, layer: *Layer, done: bool) void
/// ```
///
/// SINCE: 0.1. LVO -64.
///
/// INPUTS:
/// - `layer` - the layer.
/// - `done` - true if all of the damage was drawn, which clears it. False
///   keeps it, so the layer still owes a redraw and the next `BeginUpdate`
///   offers the same again.
///
/// RESULT:
/// Nothing. Without an update on, nothing happens.
///
/// BEHAVIOR:
/// The clip list `BeginUpdate` put aside comes back, and the narrowed one
/// is freed.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the layer.
/// - Interrupts: no. It may wait.
/// - Forbid: must not be held: waiting for the lock would break it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BeginUpdate`
///
/// EXAMPLES:
/// ```zig
/// lb.EndUpdate(layer, true);
/// ```
pub fn EndUpdate(lb: *LayersBase, layer: *Layer, done: bool) void {
    _locks.holdOne(lb, layer);
    defer _locks.releaseOne(lb, layer);
    const gb = lb.graphics_base;
    const sys = lb.sys_base;
    if (layer.flags & layers.LAYERUPDATING == 0) return;

    _layerinfo.freeTargets(sys, layer.info, layer.targets);
    layer.targets = layer.saved_targets;
    layer.saved_targets = null;
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = graphics.RPTAG_ClipTargets, .data = @intFromPtr(layer.targets) },
        .{},
    };
    gb.SetRPAttrs(layer.rp, &tags);

    layer.flags &= ~layers.LAYERUPDATING;
    // Not done means the program drew some of it and wants the rest kept,
    // so the damage stays and the layer is still owed a refresh.
    if (done) {
        gb.ClearRegion(layer.damage);
        layer.flags &= ~layers.LAYERREFRESH;
    }
}
