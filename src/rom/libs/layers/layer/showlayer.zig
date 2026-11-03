// SPDX-License-Identifier: MPL-2.0
//! ShowLayer: puts a hidden layer back into what is shown.

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const Layer = _layerinfo.Layer;
const _layer = @import("_layer.zig");
const _locks = @import("../locks/_locks.zig");
const LayersBase = @import("../layers.zig").LayersBase;

/// Puts a hidden layer back into what is shown.
///
/// SYNOPSIS:
/// ```zig
/// fn ShowLayer(lb: *LayersBase, layer: *Layer) bool
/// ```
///
/// SINCE: 0.15. LVO -144.
///
/// INPUTS:
/// - `layer` - the layer.
///
/// RESULT:
/// True, or false with `LERR_NO_MEMORY` in the layer if the tiling could
/// not be worked out. A layer that was not hidden answers true.
///
/// BEHAVIOR:
/// It is seen again where it was and as far in front as it was: it covers
/// what it covered, and what it covers loses those pixels as it would to
/// any other layer coming in front. Its own pixels come back from where
/// its kind keeps them - its buffer when it is composed, its keeping when
/// it is smart or super. A simple layer is owed all of itself as damage,
/// `LAYERREFRESH` is set and its program is told (`IDCMP_REFRESHWINDOW`,
/// where intuition owns the layer).
///
/// CONTEXT:
/// - Waits: yes, while another task holds the display's layers.
/// - Interrupts: no. It may wait, and it allocates.
/// - Locks: no spinlock may be held: it waits for locks.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated that outlives the call.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `HideLayer`, `BeginUpdate`
///
/// EXAMPLES:
/// ```zig
/// _ = lb.ShowLayer(layer);
/// ```
pub fn ShowLayer(lb: *LayersBase, layer: *Layer) bool {
    _locks.holdAll(lb, layer.info);
    defer _locks.releaseAll(lb, layer.info);
    return _layer.setHidden(lb, layer, false);
}
