// SPDX-License-Identifier: MPL-2.0
//! AreaArc: a wedge: out from the middle, round the arc, and back.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const _area = @import("_area.zig");
const RastPort = rastport.RastPort;
const drawing = @import("../draw/_draw.zig");
const addPoint = _area.addPoint;
const curveStep = _area.curveStep;

/// A wedge: out from the middle, round the arc, and back.
///
/// SYNOPSIS:
/// ```zig
/// fn AreaArc(gb: *GraphicsBase, rp: *RastPort, cx: i32, cy: i32, radius: i32, from: i32, to: i32) bool
/// ```
///
/// SINCE: 0.10. LVO -116.
///
/// INPUTS:
/// - `rp` - the RastPort, with room from `InitArea`.
/// - `cx` - the centre's column.
/// - `cy` - the centre's row.
/// - `radius` - in pixels; below 0 adds nothing.
/// - `from` - where the wedge starts, in degrees, 0 to the right and 90
///   upward, as `DrawArc` has them.
/// - `to` - where it ends. Equal to `from` adds nothing.
///
/// RESULT:
/// False, with the error in the RastPort, if the room ran out part way.
///
/// BEHAVIOR:
/// A wedge: a shape begun at the centre, out along `from`, round the arc
/// and back - so what is filled is the slice a person means by one.
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
/// `DrawArc`, `AreaEllipse`
///
/// EXAMPLES:
/// ```zig
/// _ = gb.AreaArc(rp, 100, 100, 50, 0, 90);
/// ```
pub fn AreaArc(gb: *GraphicsBase, rp: *RastPort, cx: i32, cy: i32, radius: i32, from: i32, to: i32) bool {
    const graphics_lib = gb.iface();
    rp.last_error = graphics.GERR_OK;
    if (radius < 0) return true;
    const sweep = @mod(to - from, 360);
    if (sweep == 0) return true;
    if (!graphics_lib.AreaMove(@ptrCast(rp), cx, cy)) return false;

    const step = curveStep(radius);
    var walked: i32 = 0;
    while (walked <= sweep) : (walked += step) {
        const at = from + walked;
        const x = cx + @divTrunc(radius * drawing.cosDeg(at), drawing.sine_scale);
        const y = cy - @divTrunc(radius * drawing.sinDeg(at), drawing.sine_scale);
        if (!addPoint(rp, x, y)) return false;
    }
    // The far edge exactly, whatever the step left over.
    const x = cx + @divTrunc(radius * drawing.cosDeg(from + sweep), drawing.sine_scale);
    const y = cy - @divTrunc(radius * drawing.sinDeg(from + sweep), drawing.sine_scale);
    return addPoint(rp, x, y);
}
