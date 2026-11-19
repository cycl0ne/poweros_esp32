// SPDX-License-Identifier: MIT
//! Paint's view of the picture: which part of it the window shows, at
//! which zoom, and the rows of pixels that make that up.
//!
//! The view is `width` by `height` pixels - the canvas gadget's picture,
//! which follows its box. At a zoom of N every picture pixel is N by N of
//! the view's. A picture wider or taller than the view is scrolled
//! (`left`, `top`: the picture pixel at the view's top left); a smaller
//! one sits in the middle (`offset_x`, `offset_y`) on the backdrop. From
//! a zoom of 8 a grid marks the pixels' edges. Coverage below full shows
//! a checkerboard through it, so what is see-through looks it.
//!
//! The view's rows are made here into the program's buffer, a band at a
//! time, and the program writes them into the canvas with
//! `WritePixelArray`; only the area a change touched is made again.

const picture_zig = @import("picture.zig");
const Picture = picture_zig.Picture;
const Pixel = picture_zig.Pixel;
const Area = picture_zig.Area;

/// The zooms the view steps through.
pub const zooms = [_]u32{ 1, 2, 3, 4, 6, 8, 12, 16 };
/// The least zoom the grid shows at.
pub const grid_zoom = 8;

/// What is round the picture.
pub const backdrop: Pixel = 0xFF5A5A5A;
/// The checkerboard behind what is see-through, in squares of 8.
const check_light: Pixel = 0xFFFFFFFF;
const check_dark: Pixel = 0xFFCCCCCC;
const check_shift = 3;

pub const View = struct {
    zoom: u32 = 1,
    left: i32 = 0,
    top: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    grid: bool = true,

    /// The picture's pixels across and down the view shows whole.
    pub fn columns(view: *const View) u32 {
        return view.width / view.zoom;
    }

    pub fn rows(view: *const View) u32 {
        return view.height / view.zoom;
    }

    /// The scroll kept inside the picture, and a picture smaller than the
    /// view put in its middle. After every change of size, zoom or scroll.
    pub fn fit(view: *View, picture_width: u32, picture_height: u32) void {
        fitAxis(&view.left, &view.offset_x, picture_width, view.width, view.zoom);
        fitAxis(&view.top, &view.offset_y, picture_height, view.height, view.zoom);
    }

    fn fitAxis(first: *i32, offset: *i32, picture_size: u32, view_size: u32, zoom: u32) void {
        const shown = @as(u64, picture_size) * zoom;
        if (shown <= view_size) {
            first.* = 0;
            offset.* = @intCast((view_size - shown) / 2);
            return;
        }
        offset.* = 0;
        const last: i32 = @intCast(picture_size - view_size / zoom);
        first.* = @max(0, @min(first.*, last));
    }

    /// The picture pixel under the view's pixel (`x`, `y`); outside the
    /// picture when the view's pixel is.
    pub fn toPicture(view: *const View, x: i32, y: i32) [2]i32 {
        const zoom: i32 = @intCast(view.zoom);
        return .{ view.left + @divFloor(x - view.offset_x, zoom), view.top + @divFloor(y - view.offset_y, zoom) };
    }

    /// Where an area of the picture is in the view, cut to the view;
    /// empty for an empty one, `Area.none` among them.
    pub fn toView(view: *const View, area: Area) Area {
        if (area.isEmpty()) return .{};
        const zoom: i32 = @intCast(view.zoom);
        const shown = Area{
            .min_x = view.offset_x + (area.min_x - view.left) * zoom,
            .min_y = view.offset_y + (area.min_y - view.top) * zoom,
            .max_x = view.offset_x + (area.max_x - view.left) * zoom,
            .max_y = view.offset_y + (area.max_y - view.top) * zoom,
        };
        return shown.clip(view.width, view.height);
    }

    /// The zoom changed, the picture pixel under the view's (`x`, `y`)
    /// staying there as far as the picture's edges let it.
    pub fn zoomAt(view: *View, zoom: u32, x: i32, y: i32, picture_width: u32, picture_height: u32) void {
        const under = view.toPicture(x, y);
        const new: i32 = @intCast(zoom);
        view.zoom = zoom;
        view.left = under[0] - @divFloor(x, new);
        view.top = under[1] - @divFloor(y, new);
        view.fit(picture_width, picture_height);
    }

    /// The next zoom in or out of `zooms`, as far as it goes.
    pub fn nextZoom(view: *const View, closer: bool) u32 {
        if (closer) {
            for (zooms) |zoom| if (zoom > view.zoom) return zoom;
            return view.zoom;
        }
        var at = zooms.len;
        while (at > 0) {
            at -= 1;
            if (zooms[at] < view.zoom) return zooms[at];
        }
        return view.zoom;
    }

    /// The view's row `y` from `min_x` to before `max_x`, into `out`.
    pub fn row(view: *const View, picture: *const Picture, y: i32, min_x: i32, max_x: i32, out: []Pixel) void {
        const zoom: i32 = @intCast(view.zoom);
        const down = y - view.offset_y;
        const picture_y = view.top + @divFloor(down, zoom);
        if (down < 0 or picture_y >= picture.height) {
            @memset(out[0..@intCast(max_x - min_x)], backdrop);
            return;
        }
        const pixels = picture.row(@intCast(picture_y));
        const grid_row = view.grid and view.zoom >= grid_zoom and @mod(down, zoom) == 0;
        const show_grid = view.grid and view.zoom >= grid_zoom;
        var x = min_x;
        var at: usize = 0;
        while (x < max_x) : ({
            x += 1;
            at += 1;
        }) {
            const across = x - view.offset_x;
            const picture_x = view.left + @divFloor(across, zoom);
            if (across < 0 or picture_x >= picture.width) {
                out[at] = backdrop;
                continue;
            }
            var colour = pixels[@intCast(picture_x)];
            if (colour >> 24 != 0xFF) colour = overChecks(colour, x, y);
            if (grid_row or (show_grid and @mod(across, zoom) == 0)) colour = gridded(colour);
            out[at] = colour;
        }
    }
};

/// A see-through colour laid over the checkerboard at the view's (`x`, `y`).
fn overChecks(colour: Pixel, x: i32, y: i32) Pixel {
    const check = if (((x >> check_shift) ^ (y >> check_shift)) & 1 == 0) check_light else check_dark;
    const alpha = colour >> 24;
    var mixed: Pixel = 0xFF000000;
    var shift: u5 = 0;
    while (shift < 24) : (shift += 8) {
        const over = (colour >> shift) & 0xFF;
        const under = (check >> shift) & 0xFF;
        mixed |= ((over * alpha + under * (255 - alpha) + 127) / 255) << shift;
    }
    return mixed;
}

/// A colour on the grid: half way to a middle grey, which shows on light
/// and dark alike.
fn gridded(colour: Pixel) Pixel {
    return 0xFF000000 | (((colour >> 1) & 0x007F7F7F) + 0x00404040);
}
