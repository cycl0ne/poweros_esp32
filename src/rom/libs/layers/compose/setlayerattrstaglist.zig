// SPDX-License-Identifier: MPL-2.0
//! SetLayerAttrsTagList: changes what a composed layer looks like - its
//! corners, its shadow, how much it covers, whether it counts.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;
const TagItem = sdk.utility.TagItem;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const Layer = _layerinfo.Layer;
const compose = @import("_compose.zig");
const effects = @import("_effects.zig");
const tile = @import("../tile/_tile.zig");
const _locks = @import("../locks/_locks.zig");
const LayersBase = @import("../layers.zig").LayersBase;

/// Changes what a composed layer looks like.
///
/// SYNOPSIS:
/// ```zig
/// fn SetLayerAttrsTagList(lb: *LayersBase, layer: *Layer, tags: ?[*]const TagItem) bool
/// ```
///
/// SINCE: 0.8. LVO -132.
///
/// INPUTS:
/// - `layer` - the layer.
/// - `tags` - any of `LATAG_Corners`, `LATAG_Shadow`, `LATAG_Opacity` and
///   `LATAG_Ghost`, as `CreateLayerTagList` takes them. The last two are
///   set on the layers that move with it (`LATAG_MovesWith`) too: a
///   window's inside comes and goes with its border.
///
/// RESULT:
/// True when the layer is as asked. False for a layer that is not
/// composed, which has none of them, and without the memory for a
/// shadow's picture or the tiling: then the layer has no shadow, and
/// `LERR_NO_MEMORY` in it.
///
/// BEHAVIOR:
/// The display is shown again wherever the layer and its shadow were and
/// are: a layer seen through laid over what is behind it at its new
/// opacity, what it uncovers or covers anew copied. A tag not given
/// leaves that as it was, and one this library does not know is ignored.
/// A layer with no buffer (`LATAG_NoBuffer`) is always opaque: its
/// `LATAG_Opacity` is ignored. Set once a frame, it is how a layer fades in or out: from 0 to 255 as
/// it comes, the other way round as it goes, a ghost (`LATAG_Ghost`) so
/// that nothing is meant for it meanwhile, then deleted.
///
/// CONTEXT:
/// - Waits: yes, while another task holds any of the display's layers.
/// - Interrupts: no. It may wait, and it allocates.
/// - Locks: every layer of the display, taken here; no spinlock may be
///   held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// A shadow's picture is the LayerInfo's, kept for every layer that has
/// a shadow of that size until the LayerInfo goes.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateLayerTagList`, `GetLayerAttrs`
///
/// EXAMPLES:
/// ```zig
/// // One step of a window fading in.
/// const step = [_]TagItem{ .{ .tag = layers.LATAG_Opacity, .data = value }, .{} };
/// _ = lb.SetLayerAttrsTagList(layer, &step);
/// ```
pub fn SetLayerAttrsTagList(lb: *LayersBase, layer: *Layer, tags: ?[*]const TagItem) bool {
    const info = layer.info;
    if (!compose.on(info)) return false;
    _locks.holdAll(lb, info);
    defer _locks.releaseAll(lb, info);
    const was_reach = effects.reach(layer);
    const was = .{ layer.corners, layer.shadow, layer.opacity == 255 };
    var ok = true;
    var rest = tags;
    while (lb.utility_base.NextTagItem(&rest)) |item| {
        switch (item.tag) {
            layers.LATAG_Corners => layer.corners = @intCast(@min(item.data, 0xFFFF)),
            layers.LATAG_Shadow => layer.shadow = @intCast(@min(item.data, effects.most_shadow)),
            // A bare layer is painted, not laid over what is behind it.
            layers.LATAG_Opacity => if (!compose.bare(layer)) {
                layer.opacity = @intCast(@min(item.data, 255));
            },
            layers.LATAG_Ghost => layer.ghost = item.data != 0,
            else => {},
        }
    }
    // A layer moving with it - a window's inside, with its border - comes
    // and goes with it.
    var others = info.layers.iterator();
    while (others.next()) |node| {
        const other: *Layer = @fieldParentPtr("node", node);
        if (other.moves_with != layer) continue;
        other.opacity = layer.opacity;
        other.ghost = layer.ghost;
    }
    if (layer.shadow != 0 and !effects.makeShadow(lb, info, layer.shadow)) {
        layer.shadow = 0;
        ok = false;
    }
    // Its shape, its shadow or whether it covers what is behind: what
    // every layer can see is worked out again. Only how much it covers,
    // changed, is not geometry.
    if (layer.corners != was[0] or layer.shadow != was[1] or (layer.opacity == 255) != was[2]) {
        if (!tile.retile(lb, info)) ok = false;
    }
    // The layers moving with it are inside it: what is shown again shows
    // them too.
    compose.show(lb, info, graphics.Rect.unionWith(was_reach, effects.reach(layer)));
    layer.last_error = if (ok) layers.LERR_OK else layers.LERR_NO_MEMORY;
    return ok;
}
