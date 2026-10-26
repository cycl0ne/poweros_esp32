// SPDX-License-Identifier: MIT
//! The desktop's ground: what `ENV:Sys/anvil.prefs` says lies under the
//! icons - a colour, two shaded from the top down, a picture over either.
//!
//! **It is painted where it is seen**, by the window's backfill hook,
//! over whatever part it is called for (`scene.zig`), and kept in no more
//! memory than that needs. A colour and a gradient keep nothing: the
//! whole ground is filled through a RastPort clipped to the part, so a
//! gradient meets itself wherever two parts join. A picture tiled or
//! centred keeps its own pixels, laid over the colour where they reach
//! the part. Only a picture scaled to cover is painted once, with the
//! colour under it, into a bitmap the size of the ground in the screen's
//! own format, which the part is copied from: it is read and scaled once
//! rather than at every move of a window over it.
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
    width: i32,
    height: i32,
    /// The colour under any picture: `top` shaded down to `bottom`, one
    /// colour when they are the same.
    top: Pen,
    bottom: Pen,
    /// A picture scaled to cover, painted once with the colour under it;
    /// null for any other ground.
    surface: ?*rtg.Surface = null,
    /// A picture tiled or centred: its own pixels, bgra32, a row after
    /// another with nothing between; null for any other ground.
    pixels: ?[*]u8 = null,
    picture_width: i32 = 0,
    picture_height: i32 = 0,
    place: anvil_prefs.Place = .tiled,
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
    if (width <= 0 or height <= 0) return null;
    const memory = sys.AllocVec(@sizeOf(Ground), exec.MEMF_CLEAR) orelse return null;
    const ground: *Ground = @ptrCast(@alignCast(memory));
    const top: Pen = if (settings.ground_given) settings.top else background;
    const bottom: Pen = if (settings.ground_given) settings.bottom else background;
    ground.* = .{ .width = width, .height = height, .top = top, .bottom = bottom, .light = isLight(between(top, bottom)) };
    if (settings.pictureName()) |name| {
        if (libs.dt) |dt| if (keepPicture(libs, dt, ground, settings, name, friend)) |mean| {
            ground.light = isLight(mean);
        };
    }
    return ground;
}

/// The picture named in the settings kept as the ground paints it: its
/// pixels, or scaled into a bitmap of the ground's size with the colour
/// under it. Its average colour, or null when it could not be read or
/// there was no memory to keep it.
fn keepPicture(libs: Libs, dt: *DataTypesBase, ground: *Ground, settings: *const anvil_prefs.Settings, name: []const u8, friend: *graphics.RastPort) ?Pen {
    const sys = libs.sys;
    const gb = libs.gb;
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
    const row: u32 = @intCast(pitch);

    if (settings.place == .scaled) {
        const surface = gb.AllocBitMapTagList(&[_]TagItem{
            .{ .tag = graphics.BMTAG_Width, .data = @intCast(ground.width) },
            .{ .tag = graphics.BMTAG_Height, .data = @intCast(ground.height) },
            .{ .tag = graphics.BMTAG_Friend, .data = @intFromPtr(friend) },
            .{},
        }) orelse return null;
        const rp = gb.CreateRastPortTagList(&[_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(surface) }, .{} }) orelse {
            gb.FreeBitMap(surface);
            return null;
        };
        defer gb.FreeRastPort(rp);
        const whole = Rect{ .max_x = ground.width, .max_y = ground.height };
        paintColour(gb, ground, rp, whole);
        const source = Rect{ .max_x = picture_width, .max_y = picture_height };
        const at = cover(picture_width, picture_height, ground.width, ground.height);
        gb.ScalePixelArray(rp, bytes, row, @intFromEnum(rtg.PixelFormat.bgra32), &source, &at);
        ground.surface = surface;
    } else {
        const tight: usize = @as(usize, @intCast(picture_width)) * 4;
        const size = tight * @as(usize, @intCast(picture_height));
        const kept = sys.AllocVec(@intCast(size), exec.MEMF_ANY) orelse return null;
        const into: [*]u8 = @ptrCast(kept);
        var y: usize = 0;
        while (y < picture_height) : (y += 1) @memcpy(into[y * tight ..][0..tight], bytes[y * row ..][0..tight]);
        ground.pixels = into;
        ground.picture_width = picture_width;
        ground.picture_height = picture_height;
        ground.place = settings.place;
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
    if (kept.surface) |surface| libs.gb.FreeBitMap(surface);
    if (kept.pixels) |pixels| libs.sys.FreeVec(pixels);
    libs.sys.FreeVec(kept);
}

/// `area` of a window painted with the ground, through `rp` - clipped to
/// the area while it paints, as it was after. Its pens and fill are left
/// as the ground needed them.
pub fn paint(gb: *GraphicsBase, ground: *const Ground, rp: *graphics.RastPort, area: Rect) void {
    const whole = Rect{ .max_x = ground.width, .max_y = ground.height };
    const part = Rect.intersect(area, whole);
    if (part.isEmpty()) return;
    if (ground.surface) |surface| {
        gb.BltBitMapRastPort(surface, part.min_x, part.min_y, rp, part.min_x, part.min_y, part.width(), part.height());
        return;
    }
    var was: Rect = undefined;
    gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&was) }, .{} });
    const within = Rect.intersect(was, part);
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&within) }, .{} });
    defer gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&was) }, .{} });
    paintColour(gb, ground, rp, part);
    const pixels = ground.pixels orelse return;
    const pw = ground.picture_width;
    const ph = ground.picture_height;
    const pitch: u32 = @intCast(pw * 4);
    const format = @intFromEnum(rtg.PixelFormat.bgra32);
    switch (ground.place) {
        // Only the tiles the part meets: a small picture is many of them.
        .tiled => {
            var y = @divFloor(part.min_y, ph) * ph;
            while (y < part.max_y) : (y += ph) {
                var x = @divFloor(part.min_x, pw) * pw;
                while (x < part.max_x) : (x += pw) {
                    const tile = Rect.intersect(.{ .min_x = x, .min_y = y, .max_x = x + pw, .max_y = y + ph }, whole);
                    gb.BlendPixelArray(rp, pixels, pitch, format, 0, 0, &tile);
                }
            }
        },
        .centred => {
            const at = centred(pw, ph, ground.width, ground.height);
            // A picture larger than the ground shows its middle.
            const shown = Rect.intersect(at, whole);
            if (shown.isEmpty()) return;
            gb.BlendPixelArray(rp, pixels, pitch, format, shown.min_x - at.min_x, shown.min_y - at.min_y, &shown);
        },
        // Kept as the bitmap, painted above.
        .scaled => {},
    }
}

/// The ground's colour, or its gradient over the whole ground, through
/// `rp` - which the caller has clipped to `part`, so a gradient painted a
/// part at a time comes out as one painted whole.
fn paintColour(gb: *GraphicsBase, ground: *const Ground, rp: *graphics.RastPort, part: Rect) void {
    if (ground.top == ground.bottom) {
        gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = ground.top }, .{} });
        gb.RectFill(rp, &part);
        return;
    }
    var fill = graphics.FillStyle{};
    fill.stops[0].pen = ground.top;
    fill.stops[1].pen = ground.bottom;
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FillStyle, .data = @intFromPtr(&fill) }, .{} });
    gb.RectFill(rp, &.{ .max_x = ground.width, .max_y = ground.height });
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FillStyle, .data = 0 }, .{} });
}
