// SPDX-License-Identifier: MPL-2.0
//! EraseRect: sYNOPSIS

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const Rect = graphics.Rect;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _rastport = @import("_rastport.zig");
const draw = @import("../draw/_draw.zig");
const RastPort = _rastport.RastPort;

/// Paints part of a RastPort the way its empty parts are meant to look.
///
/// SYNOPSIS:
/// ```zig
/// fn EraseRect(gb: *GraphicsBase, rp: *RastPort, area: *const graphics.Rect) void
/// ```
///
/// SINCE: 0.17. LVO -260.
///
/// INPUTS:
/// - `rp` - the RastPort to paint in.
/// - `area` - what to paint, in its coordinates, half-open as every
///   rectangle here is.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// What to paint with is what `RPTAG_BackFill` says:
///
/// - a **`*utility.Hook`**: called once with the RastPort as its object and
///   a `BackFillMsg` carrying `area`. The hook draws through that same
///   RastPort, so what it puts down is clipped exactly as anything else
///   drawn through it - it need not know what it can be seen through, or
///   whether it can be seen at all.
/// - **`BACKFILL_NONE`**: nothing is written.
/// - **0**, which is what a RastPort has until something says otherwise:
///   the area is filled with the RastPort's own background pen.
///
/// The pen and the draw mode are put back as they were, and the fill is
/// plain whatever mode was set - a caller that left COMPLEMENT on does not
/// get it applied to the ground.
///
/// This library does not know what a window or a layer is. It knows that a
/// RastPort may carry a hook saying how its empty parts look, and it calls
/// it. Whatever manages windows is what sets that hook.
///
/// CONTEXT:
/// - Waits: only if the hook does.
/// - Interrupts: no. It draws, and it may call a hook.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The hook is the caller's; this call neither keeps nor frees it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RectFill`, `SetRPAttrs`
///
/// EXAMPLES:
/// ```zig
/// gb.EraseRect(rp, &.{ .min_x = 0, .min_y = 0, .max_x = 200, .max_y = 100 });
/// ```
pub fn EraseRect(gb: *GraphicsBase, rp: *RastPort, area: *const graphics.Rect) void {
    const graphics_lib = gb.iface();
    if (rp.backfill == graphics.BACKFILL_NONE) return;
    if (rp.backfill != 0) {
        const hook: *sdk.utility.Hook = @ptrFromInt(rp.backfill);
        var msg = graphics.BackFillMsg{ .area = area.* };
        _ = gb.utility_base.CallHookPkt(hook, @ptrCast(rp), @ptrCast(&msg));
        return;
    }
    // Nothing said how: the RastPort's own background pen, plainly, with
    // what the caller had set put back. Both pens are already packed for
    // this surface, so swapping them needs no conversion.
    const pen = rp.fg_pen;
    const packed_pen = rp.fg_packed;
    const mode = rp.draw_mode;
    rp.fg_pen = rp.bg_pen;
    rp.fg_packed = rp.bg_packed;
    rp.draw_mode = graphics.DRMD_JAM1;
    graphics_lib.RectFill(@ptrCast(rp), area);
    rp.fg_pen = pen;
    rp.fg_packed = packed_pen;
    rp.draw_mode = mode;
}
