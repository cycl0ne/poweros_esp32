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
//! a checkerboard through it, so what is see-through looks it. The brush
//! under the pointer (`brush.Ghost`) is laid over the rows as they are
//! made, so it is seen and never in the picture, and so is the outline
//! of what is chosen (selection.zig): a view pixel on the side of a
//! chosen picture pixel that faces one not chosen is a dash, four pixels
//! black and four white along the view's diagonals, which shows on any
//! colour and at any zoom. While the palette cycles, each pixel of a
//! range's colours is shown as the colour that has turned onto its place
//! (`turned`); the picture itself is left. While a free transform is
//! under way its frame (`transform.Frame`) is laid over each row last,
//! over the backdrop too, since what is turned or moved may reach past
//! the picture.
//!
//! The view's rows are made here into the program's buffer, a band at a
//! time, and the program writes them into the canvas with
//! `WritePixelArray`; only the area a change touched is made again. A
//! view is a part of the canvas (`x`, `y`): the rulers' strips are above
//! and left of it when they are shown, and with Split Screen two views
//! share the canvas side by side. Everything here counts from the
//! view's own top left. The rulers tick every few picture pixels
//! (`rulerSteps`), so ticks never crowd and numbers have room.

const picture_zig = @import("picture.zig");
const Picture = picture_zig.Picture;
const Pixel = picture_zig.Pixel;
const Area = picture_zig.Area;
const Ghost = @import("brush.zig").Ghost;
const Outline = @import("selection.zig").Outline;
const Turned = @import("palette.zig").Turned;
const Frame = @import("transform.zig").Frame;

/// The zooms the view steps through.
pub const zooms = [_]u32{ 1, 2, 3, 4, 6, 8, 12, 16 };
/// The least zoom the grid shows at.
pub const grid_zoom = 8;

/// What is round the picture.
pub const backdrop: Pixel = 0xFF303030;
/// The checkerboard behind what is see-through, in squares of 8.
const check_light: Pixel = 0xFFFFFFFF;
const check_dark: Pixel = 0xFFCCCCCC;
const check_shift = 3;

pub const View = struct {
    /// Where its top left is in the canvas.
    x: i32 = 0,
    y: i32 = 0,
    zoom: u32 = 1,
    left: i32 = 0,
    top: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    grid: bool = true,
    /// While the palette cycles, the colours shown in place of its
    /// ranges' own.
    turned: ?*const Turned = null,
    /// A free transform's frame, in the view's pixels, while one is under
    /// way.
    frame: ?*const Frame = null,

    /// The picture's pixels across and down the view shows whole.
    pub fn columns(view: *const View) u32 {
        return view.width / view.zoom;
    }

    pub fn rows(view: *const View) u32 {
        return view.height / view.zoom;
    }

    /// Whether the canvas's pixel (`x`, `y`) is one of the view's.
    pub fn contains(view: *const View, x: i32, y: i32) bool {
        return x >= view.x and y >= view.y and x - view.x < view.width and y - view.y < view.height;
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

    /// The largest of `zooms` the whole picture shows at, or 1 when it
    /// is larger than the view.
    pub fn fitZoom(view: *const View, picture_width: u32, picture_height: u32) u32 {
        var best: u32 = 1;
        for (zooms) |zoom| {
            if (picture_width * zoom <= view.width and picture_height * zoom <= view.height) best = zoom;
        }
        return best;
    }

    /// The view moved by a drag, as a hand moves paper: `start` its
    /// corner when the drag began at the view's `from`, now at `to`.
    pub fn panTo(view: *View, start: [2]i32, from: [2]i32, to: [2]i32, picture_width: u32, picture_height: u32) void {
        const zoom: i32 = @intCast(view.zoom);
        view.left = start[0] - @divTrunc(to[0] - from[0], zoom);
        view.top = start[1] - @divTrunc(to[1] - from[1], zoom);
        view.fit(picture_width, picture_height);
    }

    /// The view's row `y` from `min_x` to before `max_x`, into `out`, the
    /// brush shown over it where `ghost` is, the edge of what `outline`
    /// chooses, and the transform's frame.
    pub fn row(view: *const View, picture: *const Picture, y: i32, min_x: i32, max_x: i32, out: []Pixel, ghost: ?*const Ghost, outline: ?*const Outline) void {
        const zoom: i32 = @intCast(view.zoom);
        const down = y - view.offset_y;
        const picture_y = view.top + @divFloor(down, zoom);
        const shown = out[0..@intCast(max_x - min_x)];
        const marks = if (view.frame) |frame| frame.marks(y) else null;
        if (down < 0 or picture_y >= picture.height) {
            @memset(shown, backdrop);
            if (marks) |*laid| laid.lay(shown, y, min_x);
            return;
        }
        const pixels = picture.row(@intCast(picture_y));
        // The brush, when it reaches this row.
        const brush: ?*const Ghost = if (ghost) |given| (if (given.crosses(picture_y)) given else null) else null;
        const grid_row = view.grid and view.zoom >= grid_zoom and @mod(down, zoom) == 0;
        const show_grid = view.grid and view.zoom >= grid_zoom;
        // The outline, when what it chooses reaches this row.
        const edges: ?*const Outline = if (outline) |given| (if (picture_y >= given.box.min_y and picture_y < given.box.max_y) given else null) else null;
        const sub_y = @mod(down, zoom);
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
            if (view.turned) |turned| colour = turned.map(colour);
            if (brush) |laid| colour = laid.shown(picture_x, picture_y, colour);
            if (colour >> 24 != 0xFF) colour = overChecks(colour, x, y);
            if (grid_row or (show_grid and @mod(across, zoom) == 0)) colour = gridded(colour);
            if (edges) |chosen| if (onEdge(chosen, picture_x, picture_y, @mod(across, zoom), sub_y, zoom)) {
                colour = if ((((x + y) >> 2) & 1) == 0) 0xFF000000 else 0xFFFFFFFF;
            };
            out[at] = colour;
        }
        if (marks) |*laid| laid.lay(shown, y, min_x);
    }
};

/// A ruler's ticks, in picture pixels: one every `minor`, numbered every
/// `major`, a multiple of it. Steps go 1, 2, 5, 10, 20, 50, ... so the
/// ticks are 6 view pixels apart at least and the numbers 64.
pub const RulerSteps = struct { minor: i32, major: i32 };

pub fn rulerSteps(zoom: u32) RulerSteps {
    const least_tick = 6;
    const least_number = 64;
    var minor: i32 = 0;
    var major: i32 = 0;
    var step: i32 = 1;
    var scale: i32 = 1;
    while (major == 0) {
        for ([_]i32{ 1, 2, 5 }) |times| {
            step = times * scale;
            const apart = step * @as(i32, @intCast(zoom));
            if (minor == 0 and apart >= least_tick) minor = step;
            if (minor != 0 and major == 0 and apart >= least_number and @mod(step, minor) == 0) major = step;
        }
        scale *= 10;
    }
    return .{ .minor = minor, .major = major };
}

/// `value` written out in digits, a minus first when it is below 0.
pub fn numberText(value: i32, into: *[12]u8) []const u8 {
    var left: u32 = @abs(value);
    var at: usize = into.len;
    while (true) {
        at -= 1;
        into[at] = '0' + @as(u8, @intCast(left % 10));
        left /= 10;
        if (left == 0) break;
    }
    if (value < 0) {
        at -= 1;
        into[at] = '-';
    }
    return into[at..];
}

/// Whether the view pixel at (`sub_x`, `sub_y`) within the picture pixel
/// (`x`, `y`), `zoom` a side, is on the edge of what is chosen: the pixel
/// chosen, and the view pixel on a side of it facing one that is not.
fn onEdge(outline: *const Outline, x: i32, y: i32, sub_x: i32, sub_y: i32, zoom: i32) bool {
    if (!outline.chosen(x, y)) return false;
    return (sub_x == 0 and !outline.chosen(x - 1, y)) or
        (sub_x == zoom - 1 and !outline.chosen(x + 1, y)) or
        (sub_y == 0 and !outline.chosen(x, y - 1)) or
        (sub_y == zoom - 1 and !outline.chosen(x, y + 1));
}

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
