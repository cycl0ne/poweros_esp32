// SPDX-License-Identifier: MIT
//! The brush the picture is made with: vector.library's canvas over the
//! window's pens, one path built again for each shape, and the few ways
//! a shape is painted here - a colour, a gradient down or across, one
//! round a point - with the layers a soft shadow or a see-through group
//! is drawn on.
//!
//! The pens are 0xAARRGGBB, which is rtg's bgra32 in memory: the picture
//! goes onto the canvas gadget's RastPort with WritePixelArray in that
//! format once it is drawn (`view.zig`).

const sdk = @import("sdk");
const vector = sdk.vector;
const graphics = sdk.graphics;
const VectorBase = sdk.interface.vector.VectorBase;
pub const Colour = vector.Colour;
pub const Stop = vector.Stop;
pub const Paint = vector.Paint;

/// A colour from 0xRRGGBB and how much of it covers, 0 to 1.
pub fn rgb(hex: u32, alpha: f32) Colour {
    return .{
        .r = @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
        .g = @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
        .b = @as(f32, @floatFromInt(hex & 0xFF)) / 255.0,
        .a = alpha,
    };
}

/// The colour `amount` of the way from `from` to `to`.
pub fn mix(from: Colour, to: Colour, amount: f32) Colour {
    const keep = 1 - amount;
    return .{
        .r = from.r * keep + to.r * amount,
        .g = from.g * keep + to.g * amount,
        .b = from.b * keep + to.b * amount,
        .a = from.a * keep + to.a * amount,
    };
}

pub const Brush = struct {
    vb: *VectorBase,
    canvas: *vector.Canvas,
    path: *vector.Path,

    /// The path emptied for the next shape.
    pub fn begin(brush: *const Brush) *vector.Path {
        brush.vb.ClearPath(brush.path);
        return brush.path;
    }

    pub fn fill(brush: *const Brush, paint: *const Paint) void {
        _ = brush.vb.FillPath(brush.canvas, brush.path, null, paint, vector.RULE_NONZERO);
    }

    pub fn fillEvenOdd(brush: *const Brush, paint: *const Paint) void {
        _ = brush.vb.FillPath(brush.canvas, brush.path, null, paint, vector.RULE_EVENODD);
    }

    pub fn stroke(brush: *const Brush, paint: *const Paint, width: f32) void {
        const how = vector.Stroke{ .width = width, .join = vector.JOIN_ROUND, .cap = vector.CAP_ROUND };
        _ = brush.vb.StrokePath(brush.canvas, brush.path, null, paint, &how);
    }

    // --- shapes -------------------------------------------------------------------

    pub fn circle(brush: *const Brush, x: f32, y: f32, radius: f32) void {
        brush.vb.AddEllipse(brush.begin(), x, y, radius, radius);
    }

    pub fn roundRect(brush: *const Brush, x: f32, y: f32, width: f32, height: f32, radius: f32) void {
        brush.vb.AddRect(brush.begin(), &.{ .x = x, .y = y, .width = width, .height = height }, radius, radius);
    }

    /// One line, its ends round.
    pub fn line(brush: *const Brush, x1: f32, y1: f32, x2: f32, y2: f32) void {
        const path = brush.begin();
        brush.vb.MoveTo(path, x1, y1);
        brush.vb.LineTo(path, x2, y2);
    }

    // --- layers ---------------------------------------------------------------------

    /// What is drawn until `drop` goes onto a layer put down at `opacity`.
    pub fn layer(brush: *const Brush, opacity: f32) bool {
        return brush.vb.PushLayer(brush.canvas, opacity) == vector.VECTOR_OK;
    }

    /// The layer softened by `deviation` pixels.
    pub fn blur(brush: *const Brush, deviation: f32) void {
        _ = brush.vb.BlurLayer(brush.canvas, deviation, deviation);
    }

    pub fn drop(brush: *const Brush) void {
        brush.vb.PopLayer(brush.canvas);
    }
};

// --- paints -----------------------------------------------------------------------------

pub fn solid(colour: Colour) Paint {
    return .{ .kind = vector.PAINT_SOLID, .colour = colour };
}

/// Two stops, kept by the caller for as long as the paint is used.
pub const Two = [2]Stop;

pub fn two(from: Colour, to: Colour) Two {
    return .{ .{ .offset = 0, .colour = from }, .{ .offset = 1, .colour = to } };
}

/// From (x1, y1) to (x2, y2) through `stops`.
pub fn linear(stops: []const Stop, x1: f32, y1: f32, x2: f32, y2: f32) Paint {
    return .{
        .kind = vector.PAINT_LINEAR,
        .stops = stops.ptr,
        .stop_count = @intCast(stops.len),
        .x1 = x1,
        .y1 = y1,
        .x2 = x2,
        .y2 = y2,
    };
}

/// Round (x, y) out to `radius` through `stops`, lit from (fx, fy).
pub fn radial(stops: []const Stop, x: f32, y: f32, radius: f32, fx: f32, fy: f32) Paint {
    return .{
        .kind = vector.PAINT_RADIAL,
        .stops = stops.ptr,
        .stop_count = @intCast(stops.len),
        .cx = x,
        .cy = y,
        .r = radius,
        .fx = fx,
        .fy = fy,
    };
}
