// SPDX-License-Identifier: MPL-2.0
//! The locks the library takes itself, around every call that rebuilds
//! clipping. There are two kinds: one per layer, over its clipping, and
//! one per LayerInfo, over its list of layers. The calls hand them to a
//! caller; `holdAll` and `holdOne` take them for the library, through the
//! jump table like any other caller.
//!
//! Every layer's lock is also on its LayerInfo's `locks` list, so taking
//! all of them is one `ObtainSemaphoreList`. Taken one at a time, two
//! callers going opposite ways would each hold what the other waits for.

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const LayersBase = @import("../layers.zig").LayersBase;

/// Holds every layer of a display still for the length of a call.
///
/// Anything that changes what is where rebuilds clip target lists, and a
/// list being rebuilt is freed back to the pool while it is. A task
/// drawing at that moment is walking it, so the two must not overlap -
/// which is what the locks are for, and why the library takes them itself
/// rather than trusting every caller to remember.
///
/// The other half cannot be taken here: **a task drawing into a layer must
/// hold that layer's lock**, because graphics.library is the one doing the
/// walking and it has no idea layers exist. That is the contract, and it
/// is the price of the two libraries not knowing about each other.
///
/// INPUTS:
/// - `lb` - the library, called through for `LockLayers`.
/// - `info` - the display.
pub fn holdAll(lb: *LayersBase, info: *LayerInfo) void {
    const layers_lib = lb.iface();
    layers_lib.LockLayers(@ptrCast(info));
}

/// Lets go of what `holdAll` took.
///
/// INPUTS:
/// - `lb` - the library, called through for `UnlockLayers`.
/// - `info` - the display.
pub fn releaseAll(lb: *LayersBase, info: *LayerInfo) void {
    const layers_lib = lb.iface();
    layers_lib.UnlockLayers(@ptrCast(info));
}

/// Holds one layer still, for a call that touches one layer and leaves the
/// order alone.
///
/// INPUTS:
/// - `lb` - the library, called through for `LockLayer`.
/// - `layer` - the layer.
pub fn holdOne(lb: *LayersBase, layer: *Layer) void {
    const layers_lib = lb.iface();
    layers_lib.LockLayer(@ptrCast(layer));
}

/// Lets go of what `holdOne` took.
///
/// INPUTS:
/// - `lb` - the library, called through for `UnlockLayer`.
/// - `layer` - the layer.
pub fn releaseOne(lb: *LayersBase, layer: *Layer) void {
    const layers_lib = lb.iface();
    layers_lib.UnlockLayer(@ptrCast(layer));
}
