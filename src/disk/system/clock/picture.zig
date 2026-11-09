// SPDX-License-Identifier: MIT
//! The pictures the clock is put together from, and the shapes laid into
//! them. A picture is a `bgra32` surface, clear to begin with, that a
//! `shapes.Painter` lays its layers into (`into`) and that is put down in
//! one `BlendPixelArray`: worked out once and put down as often as it is
//! wanted.
//!
//! The shapes are in design units, 0 to 100 across the picture's square,
//! made into pixels without rounding them to whole ones - a hand turned to
//! any angle keeps its width, where corners on whole pixels would make it
//! thicker and thinner as it goes round.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const shapes = sdk.gadgets.shapes;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;

pub const Surface = rtg.Surface;
pub const Shape = shapes.Shape;

/// A clear picture `width` by `height` pixels; null without the memory.
pub fn make(gb: *GraphicsBase, width: i32, height: i32) ?*Surface {
    return gb.AllocBitMapTagList(&[_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = @intCast(@max(width, 1)) },
        .{ .tag = graphics.BMTAG_Height, .data = @intCast(@max(height, 1)) },
        .{ .tag = graphics.BMTAG_Format, .data = @intFromEnum(rtg.PixelFormat.bgra32) },
        .{ .tag = graphics.BMTAG_Clear, .data = 1 },
        .{},
    });
}

/// `from`'s pixels into `into`, which is as big.
pub fn copy(into: *Surface, from: *const Surface) void {
    const bytes = @as(usize, from.pitch) * from.height;
    @memcpy(into.pixels.?[0..bytes], from.pixels.?[0..bytes]);
}

/// Every pixel of it clear again.
pub fn clear(picture: *Surface) void {
    @memset(picture.pixels.?[0 .. @as(usize, picture.pitch) * picture.height], 0);
}

/// It put down on `rp` with its corner at (`x`, `y`), by its pixels'
/// own opacity.
pub fn putDown(gb: *GraphicsBase, rp: *graphics.RastPort, picture: *const Surface, x: i32, y: i32) void {
    gb.BlendPixelArray(rp, picture.pixels.?, picture.pitch, @intFromEnum(rtg.PixelFormat.bgra32), 0, 0, &.{
        .min_x = x,
        .min_y = y,
        .max_x = x + @as(i32, @intCast(picture.width)),
        .max_y = y + @as(i32, @intCast(picture.height)),
    });
}

/// A painter that lays its layers into `picture`, a square `size` pixels
/// across; `rp` is the frame's, which it does not draw on.
pub fn painter(gb: *GraphicsBase, rp: *graphics.RastPort, picture: *Surface, size: i32) shapes.Painter {
    var p = shapes.Painter.begin(.{ .gb = gb, .rp = rp, .x = 0, .y = 0, .size = size, .pens = .{} }, .{});
    p.into = picture;
    // A rim a hair wide: the clock's shapes are small parts of a large
    // picture, which the painter's own rim, a 32nd of the square, is not
    // made for.
    p.rim = @max(1, @divTrunc(size, 140));
    return p;
}

/// Straight edges through `corners`, design units in a square `size`
/// pixels across, moved by (`dx`, `dy`) units.
pub fn edges(size: i32, corners: []const [2]f32, dx: f32, dy: f32) Shape {
    const scale = @as(f32, @floatFromInt(size)) / 100;
    var shape = Shape{ .poly = .{ .corners = undefined, .count = @intCast(@min(corners.len, shapes.max_corners)) } };
    for (corners[0..shape.poly.count], 0..) |corner, at| {
        shape.poly.corners[at] = .{ (corner[0] + dx) * scale, (corner[1] + dy) * scale };
    }
    return shape;
}

/// A disc round (`cx`, `cy`) of `radius`, in design units.
pub fn disc(size: i32, cx: f32, cy: f32, radius: f32) Shape {
    return ring(size, cx, cy, radius, 0);
}

/// A ring round (`cx`, `cy`), out to `radius` and in to `inner`.
pub fn ring(size: i32, cx: f32, cy: f32, radius: f32, inner: f32) Shape {
    const scale = @as(f32, @floatFromInt(size)) / 100;
    return .{ .arc = .{ .cx = cx * scale, .cy = cy * scale, .radius = radius * scale, .inner = inner * scale, .from = 0, .to = 360 } };
}

/// A paint from the top of a shape to its bottom through three stops:
/// `top`, `middle` at `at` of the way down (of 256), and `bottom`.
pub fn downwardThrough(top: graphics.Pen, middle: graphics.Pen, at: u32, bottom: graphics.Pen) shapes.Paint {
    const one = graphics.FILL_ONE;
    return .{ .fill = .{
        .kind = graphics.FILL_LINEAR,
        .from_y = 0,
        .to_y = one,
        .count = 3,
        .stops = .{
            .{ .at = 0, .pen = top },
            .{ .at = @divTrunc(one * @as(i32, @intCast(at)), 256), .pen = middle },
            .{ .at = one, .pen = bottom },
            .{},
        },
    } };
}
