// SPDX-License-Identifier: MPL-2.0
//! Filled shapes: the area calls.
//!
//! A shape is collected as points and filled when it is closed. `AreaMove`
//! begins one, `AreaDraw` adds a corner, `AreaEllipse` and `AreaArc` add a
//! whole curve at once, and `AreaEnd` fills everything collected and starts
//! again.
//!
//! **Several shapes at a time**, because that is what gives holes. The fill
//! is even-odd: a scanline is crossed by the edges of every shape, the
//! crossings are sorted, and the pixels between the first and second, the
//! third and fourth, and so on are the inside. A shape drawn inside another
//! is therefore a hole, with no rule needed about which way round either
//! was wound.
//!
//! The curves come in as corners rather than as curves. An ellipse is cut
//! into short straight pieces off the same quarter-turn table the outline
//! calls use, so there is one fill in the file and not one per shape - and
//! nothing here needs floating point at run time either.
//!
//! The memory is the library's, taken by `InitArea` and given back by
//! `FreeRastPort`. The RastPort is opaque, so there is nowhere for a
//! caller to keep it and no reason to make it try.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const Rect = graphics.Rect;
const Point = graphics.Point;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
pub const RastPort = rastport.RastPort;
const drawing = @import("../draw/_draw.zig");

/// How the one allocation is cut up: the corners, where each shape starts,
/// and room to sort a scanline's crossings in.
///
/// Every shape needs at most one start and every corner can be a crossing,
/// so all three are the same length and the size is known from one number.
pub const bytes_per_point = @sizeOf(Point) + @sizeOf(u32) + @sizeOf(i32);

/// Where each shape's first corner is, in the RastPort's area room.
///
/// INPUTS:
/// - `rp` - the RastPort. Its area room is set up.
pub fn shapeStarts(rp: *RastPort) [*]u32 {
    const base = @intFromPtr(rp.area_points.?) + @sizeOf(Point) * rp.area_max;
    return @ptrFromInt(base);
}

/// The room to sort one row's crossings in, in the RastPort's area room.
///
/// INPUTS:
/// - `rp` - the RastPort. Its area room is set up.
pub fn crossings(rp: *RastPort) [*]i32 {
    const base = @intFromPtr(rp.area_points.?) +
        (@sizeOf(Point) + @sizeOf(u32)) * rp.area_max;
    return @ptrFromInt(base);
}

/// Give the room back, when the RastPort goes.
///
/// INPUTS:
/// - `gb` - the library, for the memory.
/// - `rp` - the RastPort.
pub fn freeArea(gb: *GraphicsBase, rp: *RastPort) void {
    if (rp.area_points) |points| gb.sys_base.FreeVec(points);
    rp.area_points = null;
    rp.area_max = 0;
    reset(rp);
}

/// Forgets every shape collected, keeping the room.
///
/// INPUTS:
/// - `rp` - the RastPort.
pub fn reset(rp: *RastPort) void {
    rp.area_count = 0;
    rp.area_shapes = 0;
}

/// Room for one more corner, and somewhere to put it.
///
/// INPUTS:
/// - `rp` - the RastPort.
/// - `x` - the corner's column.
/// - `y` - its row.
pub fn addPoint(rp: *RastPort, x: i32, y: i32) bool {
    const points = rp.area_points orelse {
        // InitArea was never called, so there is nowhere to collect.
        rp.last_error = graphics.GERR_NO_MEMORY;
        return false;
    };
    if (rp.area_count >= rp.area_max) {
        rp.last_error = graphics.GERR_BAD_SIZE;
        return false;
    }
    points[rp.area_count] = .{ .x = x, .y = y };
    rp.area_count += 1;
    return true;
}

/// How far apart to put the corners of a curve, in degrees.
///
/// A chord across `step` degrees of a circle of radius r is about
/// r * step / 57 pixels long, so a step of 57 / r keeps it to about one -
/// close enough that the edge looks drawn rather than cut. Never more than
/// 30, so a tiny curve is still a shape rather than a triangle.
///
/// INPUTS:
/// - `reach` - the curve's larger radius.
pub fn curveStep(reach: i32) i32 {
    if (reach <= 2) return 30;
    const step = @divTrunc(57, reach);
    return @max(1, @min(step, 30));
}

/// Where one shape's corners are.
///
/// INPUTS:
/// - `rp` - the RastPort.
/// - `which` - the shape's number, from 0.
pub fn shapeRange(rp: *RastPort, which: u32) struct { u32, u32 } {
    const starts = shapeStarts(rp);
    const from = starts[which];
    const to = if (which + 1 < rp.area_shapes) starts[which + 1] else rp.area_count;
    return .{ from, to };
}
