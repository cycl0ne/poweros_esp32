// SPDX-License-Identifier: MPL-2.0
//! DeleteLayer: takes a layer away, and what was behind it is uncovered.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;
const TagItem = sdk.utility.TagItem;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const tile = @import("../tile/_tile.zig");
const smart = @import("../smart/_smart.zig");
const _locks = @import("../locks/_locks.zig");
const LayersBase = @import("../layers.zig").LayersBase;

/// Takes a layer away.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteLayer(lb: *LayersBase, layer: ?*Layer) void
/// ```
///
/// SINCE: 0.1. LVO -32.
///
/// INPUTS:
/// - `layer` - the layer. Null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Its RastPort, its regions and everything it kept go back. What was
/// behind it is uncovered: a simple layer there is owed the pixels as
/// damage, a smart or super one gets them back from its keeping.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the display's layers.
/// - Interrupts: no. It may wait, and it frees memory.
/// - Forbid: must not be held: waiting for the locks would break it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The layer and its RastPort are gone. A `LAYERSUPER` bitmap stays the
/// caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateLayerTagList`, `DisposeLayerInfo`
///
/// EXAMPLES:
/// ```zig
/// lb.DeleteLayer(layer);
/// ```
pub fn DeleteLayer(lb: *LayersBase, layer: ?*Layer) void {
    const gone = layer orelse return;
    const info = gone.info;
    _locks.holdAll(lb, info);
    defer _locks.releaseAll(lb, info);
    const sys = lb.sys_base;
    const gb = lb.graphics_base;

    sys.Remove(&gone.node);
    sys.Remove(&gone.lock.link);
    // What it inherited when it joined, given back before it goes: the
    // list release will not see it any more.
    var held: u32 = 0;
    while (held < info.locked_all) : (held += 1) sys.ReleaseSemaphore(&gone.lock);

    // Whatever it was keeping goes with it: the layer is leaving, so there
    // is nothing left to put those pixels back on to.
    smart.dropKept(lb, gone);
    // The RastPort must not be left pointing at targets that are about to
    // be freed, even though it is going too.
    const none = [_]TagItem{ .{ .tag = graphics.RPTAG_ClipTargets, .data = 0 }, .{} };
    gb.SetRPAttrs(gone.rp, &none);
    _layerinfo.freeTargets(sys, info, gone.targets);
    _layerinfo.freeTargets(sys, info, gone.saved_targets);
    gb.DisposeRegion(gone.visible);
    gb.DisposeRegion(gone.damage);
    gb.FreeRastPort(gone.rp);
    sys.FreeVec(gone);

    // What was behind it can see more now.
    _ = tile.retile(lb, info);
}
