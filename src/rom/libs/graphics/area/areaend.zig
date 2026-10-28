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
const _smooth = @import("../draw/_smooth.zig");
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
/// A row takes the columns from one crossing up to and including the
/// next: a square from corner 10 to corner 60 fills columns 10 to 60 and
/// rows 10 to 59.
///
/// With `RPTAG_Smooth` the edges are smooth. Each row is asked four times,
/// a quarter of a pixel apart, and each of its pixels at four points
/// across, so an edge pixel is laid over what is there by how many of its
/// sixteen points are inside - as a smooth `FillArc` lays its edge. The
/// shape is the same one: a row still reaches the column of its right
/// crossing, so the same corners fill the same box either way, and an edge
/// along a row or a column is exactly as hard. Pixels wholly inside go
/// down as the hard fill puts them, through the pen or the fill style; an
/// edge pixel takes its colour from the fill style too, and is laid over
/// whatever the draw mode.
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

    if (rp.smooth) {
        fillSmooth(gb, rp, points, list, count, top, bottom);
        return true;
    }

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

/// Places across and down in 1024ths of a pixel. A pixel's sample points
/// lie at its odd eighths - 1, 3, 5 and 7 across and down - the grid the
/// smooth curves ask on.
const fine: i64 = 1024;
const eighth: i64 = fine / 8;

/// How many columns are worked out at a time: their coverage is kept on
/// the stack, and a row wider than this is taken in pieces.
const piece_width = 256;

/// The fill with smooth edges (`RPTAG_Smooth`): rows `top` to `bottom`,
/// over the edges in `list`, ordered by the row they begin at.
///
/// Each row is taken a piece of columns at a time. For each of its four
/// sample rows the crossings are worked out, sorted and paired as the
/// hard fill pairs them, and every sample point of the piece between a
/// pair counts towards its pixel. A pixel all sixteen of whose points are
/// inside is part of a run that goes down whole; one with some is laid
/// over by how many.
fn fillSmooth(gb: *GraphicsBase, rp: *RastPort, points: [*]const graphics.Point, list: [*]Edge, count: u32, top: i32, bottom: i32) void {
    const xs = crossings(rp);
    const styled = drawing.styled(rp);
    var cover: [piece_width]u8 = undefined;
    var bound = Rect{};
    var any = false;
    var gone: u32 = 0;
    var begun: u32 = 0;

    var y: i32 = top;
    while (y <= bottom) : (y += 1) {
        while (begun < count and lowOf(points, list[begun]) <= y) begun += 1;
        // An edge ended above is out of the list for good, as in the hard
        // fill: swapped down to where it starts.
        var k: u32 = gone;
        while (k < begun) : (k += 1) {
            const edge = list[k];
            if (y >= @max(points[edge.from].y, points[edge.to].y)) {
                list[k] = list[gone];
                list[gone] = edge;
                gone += 1;
            }
        }
        if (begun - gone < 2) continue;
        const active = list[gone..begun];

        // The columns the row reaches: an edge's crossings over the row lie
        // between those of its first and last sample rows. The right one
        // reaches a column further, as the hard fill's does.
        const first = sampleRow(y, 0);
        const last = sampleRow(y, 3);
        var low: i64 = std.math.maxInt(i64);
        var high: i64 = std.math.minInt(i64);
        for (active) |edge| {
            const a = crossAt(points, edge, first);
            const b = crossAt(points, edge, last);
            low = @min(low, @min(a, b));
            high = @max(high, @max(a, b));
        }
        const reach_left: i32 = @intCast(@max(@divFloor(low, fine), rp.clip.min_x));
        const reach_right: i32 = @intCast(@min(@divFloor(high, fine) + 2, rp.clip.max_x));

        var from = reach_left;
        while (from < reach_right) : (from += piece_width) {
            const width: usize = @intCast(@min(piece_width, reach_right - from));
            @memset(cover[0..width], 0);
            var j: i64 = 0;
            while (j < 4) : (j += 1) {
                const sy = sampleRow(y, j);
                // Crossings far to either side of the piece count only by
                // which side they are on, so they are kept within a pixel of
                // it - which also keeps them in 32 bits.
                const near_left = (@as(i64, from) - 1) * fine;
                const near_right = (@as(i64, from) + @as(i64, @intCast(width)) + 1) * fine;
                var found: u32 = 0;
                for (active) |edge| {
                    xs[found] = @intCast(std.math.clamp(crossAt(points, edge, sy), near_left, near_right));
                    found += 1;
                }
                sortCrossings(xs[0..found]);
                countSamples(xs[0..found], cover[0..width], from);
            }
            putPiece(rp, cover[0..width], from, y, styled, &bound, &any);
        }
    }
    if (any) drawing.handOn(gb, rp, drawing.written(rp.fill_box, bound));
}

/// Sample row `j` (0 to 3) of pixel row `y`, in 1024ths.
fn sampleRow(y: i32, j: i64) i64 {
    return (8 * @as(i64, y) + 2 * j + 1) * eighth;
}

/// Where an edge crosses the sample row `sy`, in 1024ths. The edge must
/// span it: a sample row lies at an odd eighth, so never on a corner.
fn crossAt(points: [*]const graphics.Point, edge: Edge, sy: i64) i64 {
    const a = points[edge.from];
    const b = points[edge.to];
    const ay = @as(i64, a.y) * fine;
    return @as(i64, a.x) * fine + @divFloor((sy - ay) * (@as(i64, b.x) - a.x), @as(i64, b.y) - a.y);
}

/// Sorted in place, as the hard fill sorts a row's crossings.
fn sortCrossings(xs: []i32) void {
    var j: usize = 1;
    while (j < xs.len) : (j += 1) {
        const key = xs[j];
        var m = j;
        while (m > 0 and xs[m - 1] > key) : (m -= 1) xs[m] = xs[m - 1];
        xs[m] = key;
    }
}

/// Counts the sample points of one sample row inside the shape into
/// `cover`, the pixels of a piece starting at column `from`. What lies
/// between the first and second crossing, the third and fourth and so on
/// is inside, up to a column past the second: two that come nearer than
/// that are taken together, so no point is counted twice.
fn countSamples(xs: []const i32, cover: []u8, from: i32) void {
    var reached: i64 = std.math.minInt(i64);
    var pair: usize = 0;
    while (pair + 1 < xs.len) : (pair += 2) {
        const l = @max(@as(i64, xs[pair]), reached);
        const r = @as(i64, xs[pair + 1]) + fine;
        reached = r;
        if (r <= l) continue;
        const piece_end = @as(i64, from) + @as(i64, @intCast(cover.len));
        var x: i64 = @max(@divFloor(l, fine), from);
        const end = @min(@divFloor(r - 1, fine) + 1, piece_end);
        while (x < end) : (x += 1) {
            const at = x * fine;
            const n: u8 = if (at >= l and at + fine <= r) 4 else samplesIn(at, l, r);
            cover[@intCast(x - from)] += n;
        }
    }
}

/// How many of the four sample points of a pixel starting at `at` lie in
/// `l` to `r`.
fn samplesIn(at: i64, l: i64, r: i64) u8 {
    var n: u8 = 0;
    var i: i64 = 0;
    while (i < 4) : (i += 1) {
        const s = at + (2 * i + 1) * eighth;
        if (s >= l and s < r) n += 1;
    }
    return n;
}

/// One piece of a row: runs of pixels wholly inside go down as the hard
/// fill puts them, and an edge pixel is laid over by its coverage.
fn putPiece(rp: *RastPort, cover: []const u8, from: i32, y: i32, styled: bool, bound: *Rect, any: *bool) void {
    var run: ?usize = null;
    for (cover, 0..) |c, i| {
        if (c == 16) {
            if (run == null) run = i;
            continue;
        }
        if (run) |start| {
            drawing.fillShapeSpan(rp, from + @as(i32, @intCast(start)), from + @as(i32, @intCast(i)), y, bound, any);
            run = null;
        }
        if (c != 0) _smooth.edgePixel(rp, from + @as(i32, @intCast(i)), y, c, styled, bound, any);
    }
    if (run) |start| drawing.fillShapeSpan(rp, from + @as(i32, @intCast(start)), from + @as(i32, @intCast(cover.len)), y, bound, any);
}

/// The row an edge begins at.
fn lowOf(points: [*]const graphics.Point, edge: Edge) i32 {
    return @min(points[edge.from].y, points[edge.to].y);
}

fn beginsAbove(points: [*]const graphics.Point, a: Edge, b: Edge) bool {
    return lowOf(points, a) < lowOf(points, b);
}
