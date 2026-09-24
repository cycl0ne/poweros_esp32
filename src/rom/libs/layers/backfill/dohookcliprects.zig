// SPDX-License-Identifier: MPL-2.0
//! DoHookClipRects: calls a hook once for each piece of a RastPort that
//! may be drawn on.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;
const utility = sdk.utility;
const Rect = graphics.Rect;
const TagItem = sdk.utility.TagItem;

const LayersBase = @import("../layers.zig").LayersBase;

/// Calls a hook once for each piece of a RastPort that may be drawn on.
///
/// SYNOPSIS:
/// ```zig
/// fn DoHookClipRects(lb: *LayersBase, hook: *utility.Hook, rp: *graphics.RastPort, area: *const graphics.Rect) void
/// ```
///
/// SINCE: 0.1. LVO -112.
///
/// INPUTS:
/// - `hook` - called with the RastPort as the object and a `BackFillMsg` as
///   the message, whose `area` is the part of `area` that piece covers, in
///   the RastPort's own coordinates.
/// - `rp` - the RastPort. It need not be a layer's: one rectangle, a clip
///   region's several, and a layer's pieces are all walked the same way.
/// - `area` - what to work over, in the RastPort's coordinates.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// What a layer can draw on is several rectangles, and once it is covered
/// they are not all in the same surface. This hands them over one at a
/// time, so that something working piece by piece - measuring, counting,
/// painting a pattern that has to be anchored - does not have to know any
/// of that. The hook draws through the RastPort, whose clipping confines
/// it. `BackFillMsg.layer` is null: a RastPort does not say which layer it
/// belongs to, and a caller that has one already knows.
///
/// CONTEXT:
/// - Waits: only if the hook does.
/// - Interrupts: no. It may allocate.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is kept. The hook and the RastPort stay the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InstallLayerHook`
///
/// EXAMPLES:
/// ```zig
/// lb.DoHookClipRects(&count_hook, rp, &whole);
/// ```
pub fn DoHookClipRects(lb: *LayersBase, hook: *utility.Hook, rp: *graphics.RastPort, area: *const graphics.Rect) void {
    // What a RastPort may be drawn on is one rectangle, or a region's
    // several, or - once layers are in the picture - a list of pieces in
    // more than one surface. All three are read back off the RastPort
    // here, so whatever wants to work over them a piece at a time does not
    // have to know which case it is in.
    const gb = lb.graphics_base;

    var targets: usize = 0;
    var region: usize = 0;
    var clip: Rect = .{};
    const ask = [_]TagItem{
        .{ .tag = graphics.RPTAG_ClipTargets, .data = @intFromPtr(&targets) },
        .{ .tag = graphics.RPTAG_ClipRegion, .data = @intFromPtr(&region) },
        .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&clip) },
        .{},
    };
    gb.GetRPAttrs(rp, &ask);

    // No layer: a RastPort does not say which one it belongs to, and
    // making it say would be the back pointer this library exists without.
    // A caller that has the layer already knows it.
    var msg = layers.BackFillMsg{ .layer = null, .area = .{} };

    if (targets != 0) {
        var at: ?*graphics.ClipTarget = @ptrFromInt(targets);
        while (at) |t| : (at = t.next) {
            const meet = Rect.intersect(Rect.intersect(t.rect, clip), area.*);
            if (meet.isEmpty()) continue;
            msg.area = meet;
            _ = lb.utility_base.CallHookPkt(hook, rp, &msg);
        }
        return;
    }

    if (region != 0) {
        const r: *graphics.Region = @ptrFromInt(region);
        const n = gb.RegionRectangles(r, null, 0);
        if (n == 0) return;
        // Room for all of them at once. This is a RastPort and not a
        // layer, so there is no pool to take it from, and a fixed buffer
        // would be a limit on how broken up a region may be.
        const bytes = n * @sizeOf(Rect);
        const mem = lb.sys_base.AllocVec(bytes, sdk.exec.MEMF_ANY) orelse return;
        defer lb.sys_base.FreeVec(mem);
        const rects: [*]Rect = @ptrCast(@alignCast(mem));
        _ = gb.RegionRectangles(r, rects, n);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const meet = Rect.intersect(Rect.intersect(rects[i], clip), area.*);
            if (meet.isEmpty()) continue;
            msg.area = meet;
            _ = lb.utility_base.CallHookPkt(hook, rp, &msg);
        }
        return;
    }

    const meet = Rect.intersect(clip, area.*);
    if (meet.isEmpty()) return;
    msg.area = meet;
    _ = lb.utility_base.CallHookPkt(hook, rp, &msg);
}
