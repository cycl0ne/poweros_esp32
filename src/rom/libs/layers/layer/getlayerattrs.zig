// SPDX-License-Identifier: MPL-2.0
//! GetLayerAttrs: reads a layer through `LATAG_Get` tags.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;
const Rect = graphics.Rect;
const TagItem = sdk.utility.TagItem;

const _layerinfo = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = _layerinfo.LayerInfo;
const Layer = _layerinfo.Layer;
const LayersBase = @import("../layers.zig").LayersBase;

/// Reads a layer.
///
/// SYNOPSIS:
/// ```zig
/// fn GetLayerAttrs(lb: *LayersBase, layer: *Layer, tags: ?[*]const TagItem) void
/// ```
///
/// SINCE: 0.1. LVO -52.
///
/// INPUTS:
/// - `layer` - the layer.
/// - `tags` - the `LATAG_Get` names, each `ti_Data` a pointer to where the
///   value goes: `LATAG_GetBounds` a `*Rect`, `LATAG_GetFlags` a `*u32`,
///   `LATAG_GetRastPort`, `LATAG_GetDamage` and `LATAG_GetInFront` a
///   `*usize`, `LATAG_GetScroll` a `*Point`, `LATAG_GetLastError` an
///   `*i32`.
///
/// RESULT:
/// Nothing; the values are where the tags point.
///
/// BEHAVIOR:
/// A tag with a null pointer is passed over, and one the library does not
/// know is ignored, so a program built against a later SDK still works.
/// `LATAG_GetInFront` answers 0 for the frontmost layer.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. What comes back is the library's: the RastPort is
/// the one to draw with, and the damage region is to be read, not kept or
/// disposed of.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateLayerTagList`, `BeginUpdate`
///
/// EXAMPLES:
/// ```zig
/// var rp: usize = 0;
/// const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetRastPort, .data = @intFromPtr(&rp) }, .{} };
/// lb.GetLayerAttrs(layer, &ask);
/// ```
pub fn GetLayerAttrs(lb: *LayersBase, layer: *Layer, tags: ?[*]const TagItem) void {
    const tag_list = tags;
    const ub = lb.utility_base;
    var rest = tag_list;
    while (ub.NextTagItem(&rest)) |item| {
        if (item.data == 0) continue;
        switch (item.tag) {
            layers.LATAG_GetBounds => @as(*Rect, @ptrFromInt(item.data)).* = layer.bounds,
            layers.LATAG_GetFlags => @as(*u32, @ptrFromInt(item.data)).* = layer.flags,
            layers.LATAG_GetRastPort => @as(*usize, @ptrFromInt(item.data)).* = @intFromPtr(layer.rp),
            layers.LATAG_GetDamage => @as(*usize, @ptrFromInt(item.data)).* = @intFromPtr(layer.damage),
            layers.LATAG_GetScroll => @as(*graphics.Point, @ptrFromInt(item.data)).* =
                .{ .x = layer.scroll_x, .y = layer.scroll_y },
            layers.LATAG_GetLastError => @as(*i32, @ptrFromInt(item.data)).* = layer.last_error,
            layers.LATAG_GetInFront => {
                const pred = layer.node.pred.?;
                const front: usize = if (pred.pred == null) 0 else @intFromPtr(@as(*Layer, @fieldParentPtr("node", pred)));
                @as(*usize, @ptrFromInt(item.data)).* = front;
            },
            else => {},
        }
    }
}
