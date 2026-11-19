// SPDX-License-Identifier: MIT
//! Paint's picture: its pixels, `0xAARRGGBB` each, a row after another
//! with nothing between the rows, and the areas a change touches.
//!
//! An `Area` is half-open, from its least corner to one past its last
//! pixel, the way graphics.library's rectangles are. What a stroke
//! changes is gathered into one with `add` as it goes, and that one area
//! is what is kept for undoing (history.zig) and drawn again
//! (view.zig).

/// A pixel: alpha, red, green and blue, a byte each from the top.
pub const Pixel = u32;

/// An area of the picture, half-open: `min` in it, `max` one past it.
pub const Area = struct {
    min_x: i32 = 0,
    min_y: i32 = 0,
    max_x: i32 = 0,
    max_y: i32 = 0,

    /// An area with nothing in it, that `add` grows from.
    pub const none = Area{ .min_x = max_coordinate, .min_y = max_coordinate, .max_x = -max_coordinate, .max_y = -max_coordinate };
    const max_coordinate = 1 << 30;

    pub fn isEmpty(area: Area) bool {
        return area.max_x <= area.min_x or area.max_y <= area.min_y;
    }

    pub fn width(area: Area) u32 {
        return if (area.isEmpty()) 0 else @intCast(area.max_x - area.min_x);
    }

    pub fn height(area: Area) u32 {
        return if (area.isEmpty()) 0 else @intCast(area.max_y - area.min_y);
    }

    /// The smallest area holding both.
    pub fn add(area: Area, other: Area) Area {
        if (other.isEmpty()) return area;
        if (area.isEmpty()) return other;
        return .{
            .min_x = @min(area.min_x, other.min_x),
            .min_y = @min(area.min_y, other.min_y),
            .max_x = @max(area.max_x, other.max_x),
            .max_y = @max(area.max_y, other.max_y),
        };
    }

    /// What of it lies inside a picture `width` by `height`.
    pub fn clip(area: Area, picture_width: u32, picture_height: u32) Area {
        const cut = Area{
            .min_x = @max(area.min_x, 0),
            .min_y = @max(area.min_y, 0),
            .max_x = @min(area.max_x, @as(i32, @intCast(picture_width))),
            .max_y = @min(area.max_y, @as(i32, @intCast(picture_height))),
        };
        return if (cut.isEmpty()) Area{} else cut;
    }
};

/// The pixels and their size. The memory is the program's, which made it.
pub const Picture = struct {
    pixels: [*]Pixel,
    width: u32,
    height: u32,

    /// The bytes a picture of this size takes.
    pub fn bytesFor(width: u32, height: u32) usize {
        return @as(usize, width) * height * @sizeOf(Pixel);
    }

    pub fn whole(picture: *const Picture) Area {
        return .{ .max_x = @intCast(picture.width), .max_y = @intCast(picture.height) };
    }

    pub fn inside(picture: *const Picture, x: i32, y: i32) bool {
        return x >= 0 and y >= 0 and x < picture.width and y < picture.height;
    }

    /// The row `y`, whole.
    pub fn row(picture: *const Picture, y: u32) []Pixel {
        const start = @as(usize, y) * picture.width;
        return picture.pixels[start .. start + picture.width];
    }

    pub fn get(picture: *const Picture, x: u32, y: u32) Pixel {
        return picture.pixels[@as(usize, y) * picture.width + x];
    }

    pub fn set(picture: *Picture, x: u32, y: u32, colour: Pixel) void {
        picture.pixels[@as(usize, y) * picture.width + x] = colour;
    }

    /// Every pixel the colour.
    pub fn fill(picture: *Picture, colour: Pixel) void {
        @memset(picture.pixels[0 .. @as(usize, picture.width) * picture.height], colour);
    }

    /// The area, cut to the picture, the colour.
    pub fn fillArea(picture: *Picture, area: Area, colour: Pixel) void {
        const cut = area.clip(picture.width, picture.height);
        if (cut.isEmpty()) return;
        var y: u32 = @intCast(cut.min_y);
        while (y < cut.max_y) : (y += 1) @memset(picture.row(y)[@intCast(cut.min_x)..@intCast(cut.max_x)], colour);
    }

    /// The area copied from `from`, a picture of the same size.
    pub fn copyArea(picture: *Picture, from: *const Picture, area: Area) void {
        const cut = area.clip(picture.width, picture.height);
        if (cut.isEmpty()) return;
        var y: u32 = @intCast(cut.min_y);
        while (y < cut.max_y) : (y += 1) {
            const into = picture.row(y)[@intCast(cut.min_x)..@intCast(cut.max_x)];
            @memcpy(into, from.row(y)[@intCast(cut.min_x)..@intCast(cut.max_x)]);
        }
    }
};
