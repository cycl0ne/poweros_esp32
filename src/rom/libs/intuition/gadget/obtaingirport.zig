// SPDX-License-Identifier: MPL-2.0
//! ObtainGIRPort: the RastPort a gadget draws into, for a moment.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classusr = intuition.classusr;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const _gadget = @import("_gadget.zig");
const hold = _gadget.hold;

/// The RastPort a gadget draws into, for a moment.
///
/// SYNOPSIS:
/// ```zig
/// fn ObtainGIRPort(ib: *IntuitionBase,
///     gadget_info: ?*classusr.GadgetInfo) ?*graphics.RastPort
/// ```
///
/// SINCE: 0.6. LVO -200.
///
/// INPUTS:
/// - `gadget_info` - from the message the gadget was sent, or null.
///
/// RESULT:
/// The window's RastPort, with the window's layer held; null for a null
/// GadgetInfo, which a gadget in no window is sent.
///
/// BEHAVIOR:
/// The layer lock is what lets a gadget draw while the program draws in the
/// same window.
///
/// CONTEXT:
/// - Waits: for the window's layer.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Lent: every one obtained is given back with `ReleaseGIRPort`, soon, and
/// the pens and draw mode as they were.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleaseGIRPort`
///
/// EXAMPLES:
/// ```zig
/// if (ib.ObtainGIRPort(msg.gadget_info)) |rp| {
///     defer ib.ReleaseGIRPort(rp);
///     // draw
/// }
/// ```
pub fn ObtainGIRPort(ib: *IntuitionBase, gadget_info: ?*classusr.GadgetInfo) ?*graphics.RastPort {
    const info_ = gadget_info orelse return null;
    const w: *Window = @ptrCast(@alignCast(info_.window));
    const gb = ib.graphics_base;
    const gi_rp = w.gi_rp orelse return null;
    // Which layer this gadget draws through, and so which one is held and
    // whose clip is copied: its own for a window with one, and for a
    // GimmeZeroZero window the border's or the interior's depending on
    // where the gadget said it belongs.
    // A requester's gadget draws through the requester's layer, and while
    // the requester is outside the window it has none to draw through.
    var from_rp = w.rp;
    var layer = w.layer;
    if (info_.requester) |req| {
        layer = req.layer orelse return null;
        var where: usize = 0;
        const ask = [_]TagItem{ .{ .tag = sdk.layers.LATAG_GetRastPort, .data = @intFromPtr(&where) }, .{} };
        ib.layers_base.GetLayerAttrs(layer, &ask);
        from_rp = @ptrFromInt(where);
    } else {
        layer = info_.layer orelse w.layer;
        from_rp = if (layer == w.layer) w.rp else _window.innerRastPort(w);
    }
    ib.layers_base.LockLayer(layer);
    if (!hold(ib, gi_rp, layer)) {
        ib.layers_base.UnlockLayer(layer);
        return null;
    }

    // Where the window's pixels are at this moment, and nothing of the
    // program's own drawing state.
    var targets: usize = 0;
    var clip: graphics.Rect = .{};
    const from = [_]TagItem{
        .{ .tag = graphics.RPTAG_ClipTargets, .data = @intFromPtr(&targets) },
        .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&clip) },
        .{},
    };
    gb.GetRPAttrs(from_rp, &from);
    const to = [_]TagItem{
        .{ .tag = graphics.RPTAG_ClipTargets, .data = targets },
        .{ .tag = graphics.RPTAG_ClipRegion, .data = 0 },
        .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&clip) },
        .{ .tag = graphics.RPTAG_APen, .data = w.detail_pen },
        .{ .tag = graphics.RPTAG_BPen, .data = w.block_pen },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
        .{},
    };
    gb.SetRPAttrs(gi_rp, &to);
    return gi_rp;
}
