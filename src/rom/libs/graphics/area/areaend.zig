// SPDX-License-Identifier: MPL-2.0
//! AreaEnd: fills everything collected and begins again.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const _area = @import("_area.zig");
const Rect = graphics.Rect;
const RastPort = rastport.RastPort;
const drawing = @import("../draw/_draw.zig");
const crossings = _area.crossings;
const reset = _area.reset;
const shapeRange = _area.shapeRange;

/// Fills everything collected and begins again.
///
/// SYNOPSIS:
/// ```zig
/// fn AreaEnd(gb: *GraphicsBase, rp: *RastPort) bool
/// ```
///
/// SINCE: 0.10. LVO -120.
///
/// INPUTS:
/// - `rp` - the RastPort with the collected shapes.
///
/// RESULT:
/// True with nothing drawn when nothing was collected, or when what was
/// collected is fewer than three corners. That is not a failure: an empty
/// shape has no inside.
///
/// BEHAVIOR:
/// Even-odd, a row at a time: every shape's edges are crossed against the
/// row, the crossings are sorted, and what lies between the first and
/// second, the third and fourth and so on is inside. A corner shared by two
/// edges is counted once - the test is half-open in y - so the crossings
/// stay even and a shape never leaks along a row.
///
/// The fill is solid. A line pattern belongs to a line, and the inside of a
/// shape is not one; the pens and the draw mode apply as everywhere else,
/// so a shape can be filled by inverting what is under it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. The work is unbounded, and it hands the rows it wrote on
///   to the display at the end.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The room stays for the next shapes; `InitArea` with 0 or `FreeRastPort`
/// gives it back.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InitArea`, `AreaMove`, `AreaDraw`
///
/// EXAMPLES:
/// ```zig
/// _ = gb.InitArea(rp, 64);
/// _ = gb.AreaMove(rp, 10, 10);   // a square
/// _ = gb.AreaDraw(rp, 60, 10);
/// _ = gb.AreaDraw(rp, 60, 60);
/// _ = gb.AreaDraw(rp, 10, 60);
/// _ = gb.AreaCircle(rp, 35, 35, 12); // with a round hole in it
/// _ = gb.AreaEnd(rp);
/// ```
pub fn AreaEnd(gb: *GraphicsBase, rp: *RastPort) bool {
    rp.last_error = graphics.GERR_OK;
    const points = rp.area_points orelse {
        rp.last_error = graphics.GERR_NO_MEMORY;
        return false;
    };
    defer reset(rp);
    if (rp.area_shapes == 0 or rp.area_count < 3) return true;

    // How far down the shapes reach, so only those rows are walked.
    var top = points[0].y;
    var bottom = points[0].y;
    var i: u32 = 1;
    while (i < rp.area_count) : (i += 1) {
        top = @min(top, points[i].y);
        bottom = @max(bottom, points[i].y);
    }
    top = @max(top, rp.clip.min_y);
    bottom = @min(bottom, rp.clip.max_y - 1);

    const xs = crossings(rp);
    var bound = Rect{};
    var any = false;

    var y: i32 = top;
    while (y <= bottom) : (y += 1) {
        var found: u32 = 0;
        var shape: u32 = 0;
        while (shape < rp.area_shapes) : (shape += 1) {
            const from, const to = shapeRange(rp, shape);
            if (to - from < 2) continue;
            var e: u32 = from;
            while (e < to) : (e += 1) {
                const a = points[e];
                // Closed: the last corner joins the first of its own shape.
                const b = points[if (e + 1 < to) e + 1 else from];
                if (a.y == b.y) continue;
                const low = @min(a.y, b.y);
                const high = @max(a.y, b.y);
                // Half-open in y, so a corner shared by two edges is
                // counted once and the crossings stay even.
                if (y < low or y >= high) continue;
                xs[found] = a.x + @divTrunc((y - a.y) * (b.x - a.x), b.y - a.y);
                found += 1;
            }
        }
        if (found < 2) continue;

        // Sorted in place; there are few of them and they are nearly
        // sorted already from one row to the next.
        var j: u32 = 1;
        while (j < found) : (j += 1) {
            const key = xs[j];
            var k = j;
            while (k > 0 and xs[k - 1] > key) : (k -= 1) xs[k] = xs[k - 1];
            xs[k] = key;
        }

        var pair: u32 = 0;
        while (pair + 1 < found) : (pair += 2) {
            drawing.fillSpan(rp, xs[pair], xs[pair + 1] + 1, y, &bound, &any);
        }
    }
    if (any) drawing.handOn(gb, rp, bound.min_y, bound.max_y);
    return true;
}
