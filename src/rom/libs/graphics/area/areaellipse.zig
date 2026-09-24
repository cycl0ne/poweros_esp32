// SPDX-License-Identifier: MPL-2.0
//! AreaEllipse: a whole ellipse as a shape of its own.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const addPoint = _area.addPoint;
const drawing = @import("../draw/_draw.zig");
const curveStep = _area.curveStep;
const RastPort = _area.RastPort;
const _area = @import("_area.zig");

/// A whole ellipse as a shape of its own.
///
/// SYNOPSIS:
/// ```zig
/// fn AreaEllipse(gb: *GraphicsBase, rp: *RastPort, cx: i32, cy: i32, rx: i32, ry: i32) bool
/// ```
///
/// SINCE: 0.10. LVO -108.
///
/// INPUTS:
/// - `rp` - the RastPort, with room from `InitArea`.
/// - `cx` - the centre's column.
/// - `cy` - the centre's row.
/// - `rx` - the radius across.
/// - `ry` - the radius up and down. Either below 0 adds nothing.
///
/// RESULT:
/// False, with the error in the RastPort, if the room ran out part way;
/// the shape is then only part of an ellipse.
///
/// BEHAVIOR:
/// It arrives as corners rather than as a curve: cut into pieces short
/// enough that each is about a pixel long, off the same quarter-turn table
/// the outline calls use. So there is one fill in the library and not one
/// per kind of shape.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It changes the caller's RastPort.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The corners go into the room `InitArea` gave.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AreaCircle`, `AreaArc`, `DrawEllipse`
///
/// EXAMPLES:
/// ```zig
/// _ = gb.AreaEllipse(rp, 100, 60, 40, 20);
/// ```
pub fn AreaEllipse(gb: *GraphicsBase, rp: *RastPort, cx: i32, cy: i32, rx: i32, ry: i32) bool {
    const graphics_lib = gb.iface();
    rp.last_error = graphics.GERR_OK;
    if (rx < 0 or ry < 0) return true;
    const step = curveStep(@max(rx, ry));
    var degrees: i32 = 0;
    var first = true;
    while (degrees < 360) : (degrees += step) {
        const x = cx + @divTrunc(rx * drawing.cosDeg(degrees), drawing.sine_scale);
        const y = cy - @divTrunc(ry * drawing.sinDeg(degrees), drawing.sine_scale);
        const ok = if (first) graphics_lib.AreaMove(@ptrCast(rp), x, y) else addPoint(rp, x, y);
        first = false;
        if (!ok) return false;
    }
    return true;
}
