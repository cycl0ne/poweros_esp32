// SPDX-License-Identifier: MIT
//! The desktop's ground: what `ENV:Sys/anvil.prefs` says lies under the
//! icons - a colour, two shaded from the top down, a picture over either.
//!
//! **It is painted once**, into a bitmap the size of the desktop's window
//! in the screen's own format, and the window's backfill hook copies from
//! that bitmap whatever strip is uncovered. So a gradient meets itself
//! wherever the strips join, a picture is read and scaled once rather
//! than at every move of a window over it, and the hook - which runs on
//! whichever task uncovered the desktop - changes nothing in the
//! RastPort it is handed, the one the desktop draws its icons through.
//!
//! A picture is read through datatypes.library, in any format it knows,
//! and laid over the colour: tiled from the top-left, centred, or scaled
//! to cover the whole ground with its shape kept, cut equally at the two
//! sides that overhang.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const graphics = sdk.graphics;
const utility = sdk.utility;
const datatypes = sdk.datatypes;
const anvil_prefs = sdk.prefs.anvil;
const ExecBase = sdk.interface.exec.ExecBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const Rect = graphics.Rect;
const Pen = graphics.Pen;
const TagItem = utility.TagItem;
const pic = datatypes.pictureclass;

pub const Ground = struct {
    surface: *rtg.Surface,
    width: i32,
    height: i32,
    /// Whether it is light on the whole: the names on it are then black.
    light: bool,
};

/// What making the ground needs.
pub const Libs = struct {
    sys: *ExecBase,
    gb: *GraphicsBase,
    /// To read a picture; null leaves the picture out.
    dt: ?*DataTypesBase,
};

/// Whether a colour is light: its brightness, as the eye weighs red,
/// green and blue, past the middle.
pub fn isLight(colour: Pen) bool {
    const red = colour >> 16 & 0xFF;
    const green = colour >> 8 & 0xFF;
    const blue = colour & 0xFF;
    return red * 299 + green * 587 + blue * 114 > 140_000;
}

/// The colour halfway between two.
fn between(one: Pen, other: Pen) Pen {
    var mixed: Pen = 0xFF00_0000;
    var shift: u5 = 0;
    while (shift < 24) : (shift += 8) {
        const a = one >> shift & 0xFF;
        const b = other >> shift & 0xFF;
        mixed |= ((a + b) / 2) << shift;
    }
    return mixed;
}

/// Where a picture `width` by `height` goes to cover a ground `ground_width`
/// by `ground_height` with its shape kept: the whole picture's place,
/// overhanging the ground equally at two sides, or fitting exactly.
pub fn cover(width: i32, height: i32, ground_width: i32, ground_height: i32) Rect {
    // Wider than the ground, for its height: as high as the ground.
    if (@as(i64, width) * ground_height >= @as(i64, height) * ground_width) {
        const scaled: i32 = @intCast(@divTrunc(@as(i64, width) * ground_height, height));
        const left = @divTrunc(ground_width - scaled, 2);
        return .{ .min_x = left, .min_y = 0, .max_x = left + scaled, .max_y = ground_height };
    }
    const scaled: i32 = @intCast(@divTrunc(@as(i64, height) * ground_width, width));
    const top = @divTrunc(ground_height - scaled, 2);
    return .{ .min_x = 0, .min_y = top, .max_x = ground_width, .max_y = top + scaled };
}

/// Where a picture `width` by `height` goes in the middle of a ground,
/// overhanging it equally where it is larger.
pub fn centred(width: i32, height: i32, ground_width: i32, ground_height: i32) Rect {
    const left = @divTrunc(ground_width - width, 2);
    const top = @divTrunc(ground_height - height, 2);
    return .{ .min_x = left, .min_y = top, .max_x = left + width, .max_y = top + height };
}

/// The ground `settings` describe, `width` by `height`, in the format of
/// `friend`'s; `background` the colour when the settings give none. Null
/// without memory for it.
pub fn make(libs: Libs, settings: *const anvil_prefs.Settings, width: i32, height: i32, friend: *graphics.RastPort, background: Pen) ?*Ground {
    const sys = libs.sys;
    const gb = libs.gb;
    if (width <= 0 or height <= 0) return null;
    const memory = sys.AllocVec(@sizeOf(Ground), exec.MEMF_CLEAR) orelse return null;
    const surface = gb.AllocBitMapTagList(&[_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = @intCast(width) },
        .{ .tag = graphics.BMTAG_Height, .data = @intCast(height) },
        .{ .tag = graphics.BMTAG_Friend, .data = @intFromPtr(friend) },
        .{},
    }) orelse {
        sys.FreeVec(memory);
        return null;
    };
    const rp = gb.CreateRastPortTagList(&[_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(surface) }, .{} }) orelse {
        gb.FreeBitMap(surface);
        sys.FreeVec(memory);
        return null;
    };
    defer gb.FreeRastPort(rp);

    const top: Pen = if (settings.ground_given) settings.top else background;
    const bottom: Pen = if (settings.ground_given) settings.bottom else background;
    const whole = Rect{ .min_x = 0, .min_y = 0, .max_x = width, .max_y = height };
    if (top != bottom) {
        var fill = graphics.FillStyle{};
        fill.stops[0].pen = top;
        fill.stops[1].pen = bottom;
        gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FillStyle, .data = @intFromPtr(&fill) }, .{} });
        gb.RectFill(rp, &whole);
        gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FillStyle, .data = 0 }, .{} });
    } else {
        gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = top }, .{} });
        gb.RectFill(rp, &whole);
    }
    var light = isLight(between(top, bottom));
    if (settings.pictureName()) |name| {
        if (libs.dt) |dt| if (layPicture(dt, gb, rp, settings, name, width, height)) |mean| {
            light = isLight(mean);
        };
    }

    const ground: *Ground = @ptrCast(@alignCast(memory));
    ground.* = .{ .surface = surface, .width = width, .height = height, .light = light };
    return ground;
}

/// The picture named in the settings laid over the ground, as they say;
/// its average colour, or null when it could not be read.
fn layPicture(dt: *DataTypesBase, gb: *GraphicsBase, rp: *graphics.RastPort, settings: *const anvil_prefs.Settings, name: []const u8, width: i32, height: i32) ?Pen {
    var path: [anvil_prefs.picture_max + 1:0]u8 = @splat(0);
    @memcpy(path[0..name.len], name);
    const object = dt.NewDTObjectA(&path, &[_]TagItem{
        .{ .tag = datatypes.datatypesclass.DTA_GroupID, .data = datatypes.GID_PICTURE },
        .{},
    }) orelse return null;
    defer dt.DisposeDTObject(object);
    var header: usize = 0;
    var pixels: usize = 0;
    var pitch: usize = 0;
    _ = dt.GetDTAttrsA(object, &[_]TagItem{
        .{ .tag = pic.PDTA_BitMapHeader, .data = @intFromPtr(&header) },
        .{ .tag = pic.PDTA_Pixels, .data = @intFromPtr(&pixels) },
        .{ .tag = pic.PDTA_BytesPerRow, .data = @intFromPtr(&pitch) },
        .{},
    });
    if (header == 0 or pixels == 0) return null;
    const shape: *const pic.BitMapHeader = @ptrFromInt(header);
    const picture_width: i32 = shape.width;
    const picture_height: i32 = shape.height;
    if (picture_width == 0 or picture_height == 0) return null;
    // The picture's pens are 0xAARRGGBB words: in memory blue first.
    const bytes: [*]const u8 = @ptrFromInt(pixels);
    const format = @intFromEnum(rtg.PixelFormat.bgra32);
    const row: u32 = @intCast(pitch);
    switch (settings.place) {
        .tiled => {
            var y: i32 = 0;
            while (y < height) : (y += picture_height) {
                var x: i32 = 0;
                while (x < width) : (x += picture_width) {
                    const area = Rect{ .min_x = x, .min_y = y, .max_x = @min(x + picture_width, width), .max_y = @min(y + picture_height, height) };
                    gb.BlendPixelArray(rp, bytes, row, format, 0, 0, &area);
                }
            }
        },
        .centred => {
            const at = centred(picture_width, picture_height, width, height);
            // A picture larger than the ground shows its middle.
            const area = Rect{ .min_x = @max(at.min_x, 0), .min_y = @max(at.min_y, 0), .max_x = @min(at.max_x, width), .max_y = @min(at.max_y, height) };
            gb.BlendPixelArray(rp, bytes, row, format, area.min_x - at.min_x, area.min_y - at.min_y, &area);
        },
        .scaled => {
            const source = Rect{ .min_x = 0, .min_y = 0, .max_x = picture_width, .max_y = picture_height };
            const at = cover(picture_width, picture_height, width, height);
            gb.ScalePixelArray(rp, bytes, row, format, &source, &at);
        },
    }
    return average(bytes, row, picture_width, picture_height);
}

/// The average colour of a picture's pens, every eighth pixel each way.
fn average(bytes: [*]const u8, pitch: u32, width: i32, height: i32) Pen {
    var red: u64 = 0;
    var green: u64 = 0;
    var blue: u64 = 0;
    var count: u64 = 0;
    var y: usize = 0;
    while (y < height) : (y += 8) {
        var x: usize = 0;
        while (x < width) : (x += 8) {
            const at = y * pitch + x * 4;
            blue += bytes[at];
            green += bytes[at + 1];
            red += bytes[at + 2];
            count += 1;
        }
    }
    if (count == 0) return 0xFF00_0000;
    return 0xFF00_0000 | @as(Pen, @intCast(red / count)) << 16 | @as(Pen, @intCast(green / count)) << 8 | @as(Pen, @intCast(blue / count));
}

/// The ground given back.
pub fn free(libs: Libs, ground: ?*Ground) void {
    const kept = ground orelse return;
    libs.gb.FreeBitMap(kept.surface);
    libs.sys.FreeVec(kept);
}

/// `area` of a window painted from the ground: copied, the RastPort's
/// pens and fills left as they were.
pub fn paint(gb: *GraphicsBase, ground: *const Ground, rp: *graphics.RastPort, area: Rect) void {
    const left = @max(area.min_x, 0);
    const top = @max(area.min_y, 0);
    const right = @min(area.max_x, ground.width);
    const bottom = @min(area.max_y, ground.height);
    if (right <= left or bottom <= top) return;
    gb.BltBitMapRastPort(ground.surface, left, top, rp, left, top, right - left, bottom - top);
}
