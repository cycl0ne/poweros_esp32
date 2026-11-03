// SPDX-License-Identifier: MPL-2.0
//! HideLayer: takes a layer out of what is shown, without taking it away.

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const Layer = _layerinfo.Layer;
const _layer = @import("_layer.zig");
const _locks = @import("../locks/_locks.zig");
const LayersBase = @import("../layers.zig").LayersBase;

/// Takes a layer out of what is shown, without taking it away.
///
/// SYNOPSIS:
/// ```zig
/// fn HideLayer(lb: *LayersBase, layer: *Layer) bool
/// ```
///
/// SINCE: 0.15. LVO -140.
///
/// INPUTS:
/// - `layer` - the layer.
///
/// RESULT:
/// True, or false with `LERR_NO_MEMORY` in the layer if the tiling could
/// not be worked out. A layer that is hidden already answers true.
///
/// BEHAVIOR:
/// The layer covers nothing, is hit by nothing (`WhichLayer`) and nothing
/// of it reaches the display, while its RastPort, its regions, its damage
/// and its lock stay as they are: it is still a layer, and still in the
/// order it was in. What was behind it is uncovered as if it had gone -
/// a simple layer there is owed the pixels as damage, a smart or super
/// one gets them back from its keeping, and in a composed LayerInfo each
/// is copied out of its buffer.
///
/// Its own pixels are kept where its kind keeps them: in its buffer when
/// it is composed, in its keeping when it is smart or super. A simple
/// layer keeps nothing, so it is owed all of itself as damage when it is
/// shown again.
///
/// Drawing into a hidden layer is allowed and goes where its pixels go,
/// never on to the display: a composed layer's buffer takes it, and so
/// does a smart or super layer's keeping, as it does for a layer that is
/// covered - such a layer comes back as it was last drawn. A simple
/// layer keeps nothing, so what is drawn into it while it is away is
/// lost, and it is owed all of itself when it comes back.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the display's layers.
/// - Interrupts: no. It may wait, and it allocates.
/// - Locks: no spinlock may be held: it waits for locks.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated that outlives the call. The layer stays the
/// caller's, to show again or to delete.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ShowLayer`, `DeleteLayer`, `GetLayerAttrs`
///
/// EXAMPLES:
/// ```zig
/// _ = lb.HideLayer(layer);
/// ```
pub fn HideLayer(lb: *LayersBase, layer: *Layer) bool {
    _locks.holdAll(lb, layer.info);
    defer _locks.releaseAll(lb, layer.info);
    return _layer.setHidden(lb, layer, true);
}
