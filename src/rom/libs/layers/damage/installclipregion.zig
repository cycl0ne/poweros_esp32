// SPDX-License-Identifier: MPL-2.0
//! InstallClipRegion: narrows a layer to a region of the caller's own. It is
//! a call here rather than on the RastPort because only this library knows
//! which pieces of the layer went where: the region and the tiling have to
//! be folded together, and nothing else can do it.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const tile = @import("../tile/_tile.zig");
const _locks = @import("../locks/_locks.zig");
const LayersBase = @import("../layers.zig").LayersBase;

/// Narrows a layer to a region of the caller's own.
///
/// SYNOPSIS:
/// ```zig
/// fn InstallClipRegion(lb: *LayersBase, layer: *Layer, region: ?*graphics.Region) ?*graphics.Region
/// ```
///
/// SINCE: 0.1. LVO -56.
///
/// INPUTS:
/// - `layer` - the layer.
/// - `region` - the region, in the **layer's** coordinates, or null to take
///   one off again.
///
/// RESULT:
/// What was installed before, for the caller to dispose of, or null.
/// `LERR_NO_MEMORY` in the layer if the clipping could not be rebuilt.
///
/// BEHAVIOR:
/// It is folded together with what the layer can actually see, which only
/// this library knows. While `BeginUpdate` is on, the change takes effect
/// at `EndUpdate`.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the layer.
/// - Interrupts: no. It may wait.
/// - Forbid: must not be held: waiting for the lock would break it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The region stays the caller's and is only read. It must not be disposed
/// of or changed while it is installed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BeginUpdate`, `EndUpdate`
///
/// EXAMPLES:
/// ```zig
/// const old = lb.InstallClipRegion(layer, inner);
/// defer _ = lb.InstallClipRegion(layer, old);
/// ```
pub fn InstallClipRegion(lb: *LayersBase, layer: *Layer, region: ?*graphics.Region) ?*graphics.Region {
    _locks.holdOne(lb, layer);
    defer _locks.releaseOne(lb, layer);
    const was = layer.clip_region;
    layer.clip_region = region;
    // While an update is on, the clipping is the damage's and this takes
    // effect when it ends.
    if (layer.flags & layers.LAYERUPDATING == 0) {
        layer.last_error = if (tile.rebuild(lb, layer)) layers.LERR_OK else layers.LERR_NO_MEMORY;
    }
    return was;
}
