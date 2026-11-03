// SPDX-License-Identifier: MPL-2.0
//! FlyLayer: shows a hidden layer's picture somewhere else on the
//! display, scaled - a window on its way into the window that takes the
//! put-away ones in.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const Layer = _layerinfo.Layer;
const compose = @import("_compose.zig");
const _locks = @import("../locks/_locks.zig");
const LayersBase = @import("../layers.zig").LayersBase;

/// Shows a hidden layer's picture on the display, stretched into a
/// rectangle of its own.
///
/// SYNOPSIS:
/// ```zig
/// fn FlyLayer(lb: *LayersBase, layer: *Layer, area: *const graphics.Rect) bool
/// ```
///
/// SINCE: 0.16. LVO -148.
///
/// INPUTS:
/// - `layer` - the layer: composed, hidden (`HideLayer`) and not a super
///   one.
/// - `area` - where on the display, in its coordinates; an empty
///   rectangle ends the flight.
///
/// RESULT:
/// True when the picture is where it was asked for, or with an empty
/// rectangle when none is shown any longer. False, and nothing shown, for
/// a layer that is not composed (`LATAG_GetComposed`), a super layer, or
/// a layer that is not hidden.
///
/// BEHAVIOR:
/// What the layer was last drawn with - its buffer, all of it, border and
/// interior - is stretched on to the display at `area`, smoothly: every
/// pixel the mean of what it covers, by the board's engine where it takes
/// the job. A layer that moves with it (`LATAG_MovesWith`), a
/// GimmeZeroZero window's interior, is stretched inside it at the same
/// scale, so the whole window flies as one picture. Where the last
/// flight was is shown again first, from the layers, so nothing of the
/// picture is left behind it.
///
/// It is a picture on the display and no part of the arrangement: it
/// covers nothing, is hit by nothing, casts no shadow and has no corners
/// cut. Whatever is shown over it - a window drawing there, a layer
/// moving - covers it, and the next call draws it again, which is all an
/// animation of a fifth of a second needs. The layer itself stays hidden
/// and stays where it is: this says nothing about where it will be shown
/// when it is shown again (`ShowLayer`).
///
/// An empty rectangle ends it: the display is shown again where the
/// picture was, and the layer is a plain hidden layer. So is deleting the
/// layer (`DeleteLayer`).
///
/// CONTEXT:
/// - Waits: yes, while another task holds the display's layers.
/// - Interrupts: no. It may wait, and the engine may.
/// - Locks: every layer of the display, taken here; no spinlock may be
///   held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. `area` is only read.
///
/// NOTES:
/// A picture shown over part of the layer (`ShowLayerPicture`) is not in
/// the flight: what flies is the buffer, which holds what the layer was
/// drawn with under that picture.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `HideLayer`, `ShowLayer`, `SetLayerAttrsTagList`
///
/// EXAMPLES:
/// ```zig
/// // A window shrinking into the dock, a step at a time.
/// _ = lb.HideLayer(layer);
/// _ = lb.FlyLayer(layer, &box);
/// // ...
/// _ = lb.FlyLayer(layer, &.{});
/// ```
pub fn FlyLayer(lb: *LayersBase, layer: *Layer, area: *const graphics.Rect) bool {
    if (!compose.on(layer.info) or layer.super != null) return false;
    _locks.holdAll(lb, layer.info);
    defer _locks.releaseAll(lb, layer.info);
    if (layer.own == null) return false;
    // A layer that is shown is where the arrangement puts it; a picture of
    // it somewhere else as well would be the window twice over. Ending a
    // flight is allowed whatever the layer is, so that a caller that
    // showed the layer first still gets the display put right.
    if (!area.isEmpty() and layer.flags & layers.LAYERHIDDEN == 0) return false;
    compose.fly(lb, layer, area.*);
    return true;
}
