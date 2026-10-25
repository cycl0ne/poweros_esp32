// SPDX-License-Identifier: MPL-2.0
//! ShowLayerPicture: shows a picture of the caller's over part of a
//! composed layer, copied from where it is rather than into the layer -
//! how a swapchain's image is shown in a window without a copy on the
//! way.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const rtg = sdk.rtg;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const Layer = _layerinfo.Layer;
const compose = @import("_compose.zig");
const _locks = @import("../locks/_locks.zig");
const LayersBase = @import("../layers.zig").LayersBase;

/// Shows a picture over part of a composed layer, in place of what the
/// layer holds there.
///
/// SYNOPSIS:
/// ```zig
/// fn ShowLayerPicture(lb: *LayersBase, layer: *Layer, picture: ?*const rtg.Surface, area: ?*const graphics.Rect) bool
/// ```
///
/// SINCE: 0.7. LVO -130.
///
/// INPUTS:
/// - `layer` - the layer.
/// - `picture` - the picture, in the display's pixels; null to stop
///   showing one.
/// - `area` - where in the layer, in the **layer's** coordinates; the
///   picture's top-left lands on the area's. Cut to the picture's size.
///   Unused with no picture.
///
/// RESULT:
/// True when the picture is shown, or with null when none is any longer.
/// False, and nothing shown, for a layer that is not composed
/// (`LATAG_GetComposed`), a super layer, a picture not in the display's
/// pixels, or an area it does not reach.
///
/// BEHAVIOR:
/// What of the area can be seen is copied from the picture on to the
/// display at once, and again whenever that part of the layer is shown -
/// uncovered, moved, brought forward - for as long as the picture is
/// shown. Nothing is copied into the layer: what is drawn into the layer
/// under the area goes into its buffer and stays hidden under the
/// picture. Another picture, or another area, takes the place of the one
/// before. Null puts the picture shown until then into the layer's
/// buffer, where it stays: the display shows the same, now from the
/// layer.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the layer.
/// - Interrupts: no. It may wait.
/// - Locks: the layer's, taken here; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The picture stays the caller's, and is read by whichever task shows
/// the layer for as long as it is shown: it is not to be drawn into while
/// it is, and not to be freed before this has been called with null, or
/// the layer has been deleted. `area` is only read.
///
/// NOTES:
/// - A picture drawn into while it is shown can be copied to the display
///   half drawn. A swapchain shows one picture while the next is drawn in
///   another.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetLayerAttrs` (`LATAG_GetComposed`), `NewLayerInfoTagList`
/// (`LATAG_Compose`)
///
/// EXAMPLES:
/// ```zig
/// // The next image of a swapchain shown inside the window's border,
/// // then, as the swapchain goes, left in the window.
/// const inside = graphics.Rect{ .min_x = left, .min_y = top, .max_x = left + width, .max_y = top + height };
/// if (!lb.ShowLayerPicture(layer, &image, &inside)) copyIntoWindow(&image);
/// // ...
/// _ = lb.ShowLayerPicture(layer, null, null);
/// ```
pub fn ShowLayerPicture(lb: *LayersBase, layer: *Layer, picture: ?*const rtg.Surface, area: ?*const graphics.Rect) bool {
    if (!compose.on(layer.info) or layer.super != null) return false;
    _locks.holdOne(lb, layer);
    defer _locks.releaseOne(lb, layer);
    if (layer.own == null) return false;
    const shown = picture orelse {
        compose.keepPicture(lb, layer);
        return true;
    };
    const where = area orelse return false;
    return compose.showPicture(lb, layer, shown, where.*);
}
