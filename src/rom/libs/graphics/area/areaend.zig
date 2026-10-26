// SPDX-License-Identifier: MPL-2.0
//! AreaEnd: fills everything collected and begins again.

const std = @import("std");
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
const edges = _area.edges;
const Edge = _area.Edge;
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
/// - Waits: yes, while another task holds the RastPort's lock
///   (`RPTAG_Lock`), if it has one.
/// - Interrupts: no. The work is unbounded, and it hands the rows it wrote on
///   to the display at the end.
/// - Locks: the RastPort's own, taken here; no spinlock may be held.
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
    const held = rastport.hold(gb, rp);
    defer rastport.letGo(gb, held);
    rp.last_error = graphics.GERR_OK;
    const points = rp.area_points orelse {
        rp.last_error = graphics.GERR_NO_MEMORY;
        return false;
    };
    defer reset(rp);
    if (rp.area_shapes == 0 or rp.area_count < 3) return true;

    // How far down the shapes reach, so only those rows are walked - and
    // how far across, which with that is the box a fill style is laid
    // across.
    var top = points[0].y;
    var bottom = points[0].y;
    var left = points[0].x;
    var right = points[0].x;
    var i: u32 = 1;
    while (i < rp.area_count) : (i += 1) {
        top = @min(top, points[i].y);
        bottom = @max(bottom, points[i].y);
        left = @min(left, points[i].x);
        right = @max(right, points[i].x);
    }
    rp.fill_box = .{ .min_x = left, .min_y = top, .max_x = right + 1, .max_y = bottom + 1 };
    top = @max(top, rp.clip.min_y);
    bottom = @min(bottom, rp.clip.max_y - 1);

    // Every edge that is not level, in the order of the row it begins
    // at. A row then looks only at the edges begun above it and not yet
    // ended - kept together in `list[gone..begun]` - and not at every edge
    // of every shape: an ellipse has hundreds, and a row crosses two.
    const list = edges(rp);
    var count: u32 = 0;
    var shape: u32 = 0;
    while (shape < rp.area_shapes) : (shape += 1) {
        const from, const to = shapeRange(rp, shape);
        if (to - from < 2) continue;
        var e: u32 = from;
        while (e < to) : (e += 1) {
            // Closed: the last corner joins the first of its own shape.
            const next = if (e + 1 < to) e + 1 else from;
            if (points[e].y == points[next].y) continue;
            list[count] = .{ .from = e, .to = next };
            count += 1;
        }
    }
    std.sort.heap(Edge, list[0..count], points, beginsAbove);

    const xs = crossings(rp);
    var bound = Rect{};
    var any = false;
    var gone: u32 = 0;
    var begun: u32 = 0;

    var y: i32 = top;
    while (y <= bottom) : (y += 1) {
        while (begun < count and lowOf(points, list[begun]) <= y) begun += 1;
        var found: u32 = 0;
        var k: u32 = gone;
        while (k < begun) : (k += 1) {
            const edge = list[k];
            const a = points[edge.from];
            const b = points[edge.to];
            // Half-open in y, so a corner shared by two edges is counted
            // once and the crossings stay even. An edge ended above is out
            // of the list for good: swapped down to where it starts.
            if (y >= @max(a.y, b.y)) {
                list[k] = list[gone];
                list[gone] = edge;
                gone += 1;
                continue;
            }
            xs[found] = a.x + @divTrunc((y - a.y) * (b.x - a.x), b.y - a.y);
            found += 1;
        }
        if (found < 2) continue;

        // Sorted in place; there are few of them and they are nearly
        // sorted already from one row to the next.
        var j: u32 = 1;
        while (j < found) : (j += 1) {
            const key = xs[j];
            var m = j;
            while (m > 0 and xs[m - 1] > key) : (m -= 1) xs[m] = xs[m - 1];
            xs[m] = key;
        }

        var pair: u32 = 0;
        while (pair + 1 < found) : (pair += 2) {
            drawing.fillShapeSpan(rp, xs[pair], xs[pair + 1] + 1, y, &bound, &any);
        }
    }
    if (any) drawing.handOn(gb, rp, drawing.written(rp.fill_box, bound));
    return true;
}

/// The row an edge begins at.
fn lowOf(points: [*]const graphics.Point, edge: Edge) i32 {
    return @min(points[edge.from].y, points[edge.to].y);
}

fn beginsAbove(points: [*]const graphics.Point, a: Edge, b: Edge) bool {
    return lowOf(points, a) < lowOf(points, b);
}
