// SPDX-License-Identifier: MPL-2.0
//! DrawEllipse: an ellipse's outline.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const _draw = @import("_draw.zig");
const Rect = graphics.Rect;
const RastPort = rastport.RastPort;
const ellipsePoints = _draw.ellipsePoints;
const handOn = _draw.handOn;

/// An ellipse's outline.
///
/// SYNOPSIS:
/// ```zig
/// fn DrawEllipse(gb: *GraphicsBase, rp: *RastPort, cx: i32, cy: i32, rx: i32, ry: i32) void
/// ```
///
/// SINCE: 0.9. LVO -84.
///
/// INPUTS:
/// - `rp` - the RastPort. Its pen, draw mode, line pattern and clip decide
///   the result.
/// - `cx` - the centre's column.
/// - `cy` - the centre's row.
/// - `rx` - the radius across.
/// - `ry` - the radius up and down. Either below 0 draws nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Walked in two halves - where it runs mostly sideways, and where it runs
/// mostly up and down - because one decision variable cannot serve both.
/// A radius of 0 in either direction is a straight run rather than a
/// curve, and is drawn as one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. The work is unbounded, and it hands the rows it wrote on
///   to the display at the end.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DrawCircle`, `AreaEllipse`
///
/// EXAMPLES:
/// ```zig
/// gb.DrawEllipse(rp, 160, 100, 60, 30);
/// ```
pub fn DrawEllipse(gb: *GraphicsBase, rp: *RastPort, cx: i32, cy: i32, rx: i32, ry: i32) void {
    const graphics_lib = gb.iface();
    rp.last_error = graphics.GERR_OK;
    if (rx < 0 or ry < 0) return;
    if (rx == 0 or ry == 0) {
        // Flat: a run rather than a curve, which the walk below cannot do.
        if (rx == 0 and ry == 0) {
            graphics_lib.WritePixel(@ptrCast(rp), cx, cy);
        } else if (ry == 0) {
            graphics_lib.DrawHLine(@ptrCast(rp), cx - rx, cy, 2 * rx + 1);
        } else {
            graphics_lib.DrawVLine(@ptrCast(rp), cx, cy - ry, 2 * ry + 1);
        }
        return;
    }
    var step: u32 = rp.pattern_step;
    var bound = Rect{};
    var any = false;

    const a: i64 = rx;
    const b: i64 = ry;
    const aa = a * a;
    const bb = b * b;

    var x: i64 = 0;
    var y: i64 = b;
    var d: i64 = @divTrunc(bb - aa * b, 1) + @divTrunc(aa, 4);
    while (bb * x <= aa * y) {
        ellipsePoints(rp, cx, cy, @intCast(x), @intCast(y), &step, &bound, &any);
        if (d < 0) {
            d += bb * (2 * x + 3);
        } else {
            d += bb * (2 * x + 3) + aa * (2 - 2 * y);
            y -= 1;
        }
        x += 1;
    }

    x = a;
    y = 0;
    d = @divTrunc(aa - bb * a, 1) + @divTrunc(bb, 4);
    while (aa * y <= bb * x) {
        ellipsePoints(rp, cx, cy, @intCast(x), @intCast(y), &step, &bound, &any);
        if (d < 0) {
            d += aa * (2 * y + 3);
        } else {
            d += aa * (2 * y + 3) + bb * (2 - 2 * x);
            x -= 1;
        }
        y += 1;
    }
    rp.pattern_step = step;
    if (any) handOn(gb, rp, bound.min_y, bound.max_y);
}
