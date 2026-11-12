// SPDX-License-Identifier: MIT
//! A glyph that is a picture, rendered: found in the strike nearest
//! above the size asked for, read whole, and scaled to the size.
//!
//! Where it goes is worked out from its measures alone (`place`): the
//! strike's pixels times the line's em over the strike's, across and
//! down, its top from a baseline on a whole row - so that a picture
//! drawn at its strike's own size comes out pixel for pixel - and the
//! box of whole pixels that touches. The box is the picture's, not cut
//! to its ink, so how many bytes a glyph takes is known before anything
//! of it is read.
//!
//! The picture is read at its full size: coverage, a byte a pixel (0 to
//! 255), from rows of 1, 2, 4 or 8 bits or from the other glyphs it is
//! put together of; or colour, four bytes a pixel, from a PNG file
//! unpacked through compression.library. Every pixel of the box is then
//! the mean of the picture over that pixel's area - what of the area
//! lies outside the picture counting as nothing, and a colour weighted
//! by its coverage - so one rule makes a picture smaller, leaves it as
//! it is, or makes it larger. Coverage comes out in fifteenths, as an
//! outline's does, colour as red, green, blue and coverage (0 to 255),
//! the colour not multiplied by it.
//!
//! A picture that cannot be read - data too short for its rows, parts
//! nested deeper than `most_nesting` or more than `most_parts` of them,
//! a PNG file that is damaged or not the size its measures say - is its
//! box with nothing in it, so a glyph takes the bytes its measures say
//! whatever its data holds. One of no pixels, or placed further than the
//! size's reach, is a glyph of no ink.

const sdk = @import("sdk");
const exec = sdk.exec;
const decode = sdk.datatypes.png.decode;
const _outline = @import("../outline/_outline.zig");
const _strike = @import("../outline/_strike.zig");
const _render = @import("_render.zig");
const Font = _outline.Font;
const Picture = _strike.Picture;
const ExecBase = sdk.interface.exec.ExecBase;

/// How deep a picture of parts may have parts of parts, and how many
/// parts one glyph is put together of in all.
const most_nesting = 4;
const most_parts = 256;

pub const Failure = error{ NoMemory, Damaged };

/// Where a picture goes at a size.
pub const Placed = struct {
    /// The whole pixels it touches, from the point and the top of the
    /// line.
    left: i32,
    top: i32,
    width: u32,
    rows: u32,
    /// The picture's left top corner within them.
    x: f32,
    y: f32,
    /// Pixels drawn for one of the picture's, across and down.
    across: f32,
    down: f32,
};

/// Where the picture of `glyph` goes at `scale`; null for a glyph
/// without one, a picture of no pixels, or one out of reach.
pub fn boxOf(font: *const Font, glyph: u32, scale: _render.Scale) ?Placed {
    const picture = _strike.pictureOf(font, glyph, scale.rows) orelse return null;
    return place(font, &picture, scale);
}

fn place(font: *const Font, picture: *const Picture, scale: _render.Scale) ?Placed {
    const m = picture.metrics;
    if (m.width == 0 or m.rows == 0) return null;
    // The line's em over the strike's, in 64 bits: exactly 1 where the
    // two are the same.
    const line: f64 = @floatFromInt(@as(u64, scale.rows) * font.units_per_em);
    const span: f64 = @floatFromInt(font.ascender - font.descender);
    const across: f32 = @floatCast(line / (span * @as(f64, @floatFromInt(picture.strike.ppem_x))));
    const down: f32 = @floatCast(line / (span * @as(f64, @floatFromInt(picture.strike.ppem_y))));
    const baseline = @floor(scale.ascender * scale.factor + 0.5);
    const x0 = @as(f32, @floatFromInt(m.left)) * across;
    const x1 = x0 + @as(f32, @floatFromInt(m.width)) * across;
    const y0 = baseline - @as(f32, @floatFromInt(m.top)) * down;
    const y1 = y0 + @as(f32, @floatFromInt(m.rows)) * down;
    const reach = scale.reach;
    if (!(x0 >= -reach and x1 <= reach and y0 >= -reach and y1 <= reach)) return null;
    // An edge a rounding error off a pixel's border is on it.
    const snap: f32 = 1.0 / 1024.0;
    const left: i32 = @intFromFloat(@floor(x0 + snap));
    const top: i32 = @intFromFloat(@floor(y0 + snap));
    return .{
        .left = left,
        .top = top,
        .width = @intCast(@max(@as(i32, @intFromFloat(@ceil(x1 - snap))) - left, 1)),
        .rows = @intCast(@max(@as(i32, @intFromFloat(@ceil(y1 - snap))) - top, 1)),
        .x = x0 - @as(f32, @floatFromInt(left)),
        .y = y0 - @as(f32, @floatFromInt(top)),
        .across = across,
        .down = down,
    };
}

/// The picture of `glyph` rendered at `scale` into `out`, which has its
/// advance: its box and its pixels - a byte a pixel (0 to 15) for a font
/// of coverage, four for one of colour - which the caller frees. A
/// picture that cannot be read is its box with nothing in it: the box is
/// what `boxOf` said before the picture was read. `out` as it came for a
/// glyph without a picture; null only without memory.
pub fn render(sys: *ExecBase, font: *const Font, glyph: u32, scale: _render.Scale, out: _render.Rendered) ?_render.Rendered {
    const picture = _strike.pictureOf(font, glyph, scale.rows) orelse return out;
    const placed = place(font, &picture, scale) orelse return out;
    const colour = font.strikes.colour;
    const each: u32 = if (colour) 4 else 1;
    const m = picture.metrics;

    // More than the machine has addresses for is no memory.
    const bytes = @as(u64, placed.width) * placed.rows * each;
    if (bytes > ~@as(usize, 0)) return null;
    const pixels: [*]u8 = @ptrCast(sys.AllocVec(@intCast(bytes), exec.MEMF_ANY) orelse return null);

    if (read(sys, font, &picture)) |canvas| {
        defer sys.FreeVec(canvas.ptr);
        if (colour) scaled(true, canvas, m, placed, pixels) else scaled(false, canvas, m, placed, pixels);
    } else |failure| switch (failure) {
        Failure.NoMemory => {
            sys.FreeVec(pixels);
            return null;
        },
        Failure.Damaged => @memset(pixels[0..@intCast(bytes)], 0),
    }

    var done = out;
    done.left = placed.left;
    done.top = placed.top;
    done.width = placed.width;
    done.rows = placed.rows;
    done.pixels = pixels;
    return done;
}

/// A picture at its full size, its width by its rows: coverage, a byte
/// a pixel (0 to 255), or for a font of colour four bytes a pixel - red,
/// green, blue, coverage. The caller frees it.
pub fn read(sys: *ExecBase, font: *const Font, picture: *const Picture) Failure![]u8 {
    const m = picture.metrics;
    const each: u32 = if (font.strikes.colour) 4 else 1;
    const bytes = m.width * m.rows * each;
    if (bytes == 0) return Failure.Damaged;
    const memory = sys.AllocVec(bytes, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return Failure.NoMemory;
    errdefer sys.FreeVec(memory);
    const canvas = @as([*]u8, @ptrCast(memory))[0..bytes];
    if (font.strikes.colour) {
        try readPng(sys, font, picture, canvas);
    } else {
        var parts_left: u32 = most_parts;
        if (!draw(font, picture, canvas, m.width, m.rows, 0, 0, most_nesting, &parts_left)) return Failure.Damaged;
    }
    return canvas;
}

/// A picture of coverage put on `canvas`, `width` by `rows` bytes, its
/// left top corner at `x`, `y`: each pixel the larger of what is there
/// and the picture's, what falls outside left out. A picture of parts
/// is its parts, each put where it says, to `nesting` deep and
/// `parts_left` in all; a part the strike has no picture of is left
/// out. False for a picture that cannot be read.
fn draw(font: *const Font, picture: *const Picture, canvas: []u8, width: u32, rows: u32, x: i32, y: i32, nesting: u32, parts_left: *u32) bool {
    const m = picture.metrics;
    switch (picture.form) {
        .png => return false,
        .parts => {
            if (nesting == 0) return false;
            var nth: u32 = 0;
            const count = _strike.partCount(font, picture);
            while (nth < count) : (nth += 1) {
                if (parts_left.* == 0) return false;
                parts_left.* -= 1;
                const part = _strike.partAt(font, picture, nth);
                const one = _strike.pictureIn(font, picture.strike, part.glyph) orelse continue;
                if (!draw(font, &one, canvas, width, rows, x + part.x, y + part.y, nesting - 1, parts_left)) return false;
            }
            return true;
        },
        .rows, .bits => {},
    }
    // A pixel is 1, 2, 4 or 8 bits and starts on a multiple of that, so
    // none lies across two bytes.
    const depth = picture.strike.depth;
    const row_bits = if (picture.form == .rows) ((m.width * depth + 7) / 8) * 8 else m.width * depth;
    if (@as(u64, row_bits) * m.rows > @as(u64, picture.bytes.len) * 8) return false;
    const most: u32 = (@as(u32, 1) << @intCast(depth)) - 1;
    var row: u32 = 0;
    while (row < m.rows) : (row += 1) {
        const down = y + @as(i32, @intCast(row));
        if (down < 0 or down >= rows) continue;
        var column: u32 = 0;
        while (column < m.width) : (column += 1) {
            const across = x + @as(i32, @intCast(column));
            if (across < 0 or across >= width) continue;
            const bit = row * row_bits + column * depth;
            const shift: u3 = @intCast(8 - depth - (bit & 7));
            const value = (_outline.byteIn(font, picture.bytes, bit / 8) >> shift) & most;
            const at = @as(usize, @intCast(down)) * width + @as(usize, @intCast(across));
            canvas[at] = @max(canvas[at], @as(u8, @intCast(value * 255 / most)));
        }
    }
    return true;
}

/// A picture that is a PNG file read into `canvas`, four bytes a pixel:
/// red, green, blue, coverage. The file is the size the picture's
/// measures say, or it is damaged.
fn readPng(sys: *ExecBase, font: *const Font, picture: *const Picture, canvas: []u8) Failure!void {
    const cb = font.compression orelse return Failure.Damaged;
    const file = font.data[picture.bytes.at..][0..picture.bytes.len];
    const info = decode.readInfo(file) catch return Failure.Damaged;
    if (info.width != picture.metrics.width or info.height != picture.metrics.rows) return Failure.Damaged;

    var plte: []const u8 = &.{};
    var trns: []const u8 = &.{};
    var idat_length: usize = 0;
    var walk = decode.Walk.start(file) catch return Failure.Damaged;
    while (walk.next() catch return Failure.Damaged) |chunk| {
        switch (chunk.id) {
            decode.ID_PLTE => plte = chunk.data,
            decode.ID_TRNS => trns = chunk.data,
            decode.ID_IDAT => idat_length += chunk.data.len,
            decode.ID_IEND => break,
            else => {},
        }
    }
    if (idat_length == 0) return Failure.Damaged;

    // The palette, the row a pass's first row is undone against (zeroes),
    // and one row of colour for a pass whose pixels are not next to one
    // another; then every row as it unpacks, its filter byte in front.
    const first_row = info.rowBytes(info.width);
    const spare_at = @sizeOf(decode.Palette);
    const raw_at = spare_at + first_row + info.width * 4;
    const raw_size = decode.rawSize(info);
    const memory = sys.AllocVec(raw_at + raw_size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return Failure.NoMemory;
    defer sys.FreeVec(memory);
    const palette: *decode.Palette = @ptrCast(@alignCast(memory));
    palette.* = .{};
    const block: [*]u8 = @ptrCast(memory);
    const empty = block[spare_at..][0..first_row];
    const colour = block[spare_at + first_row ..][0 .. info.width * 4];
    const raw = block[raw_at..][0..raw_size];

    decode.readPalette(info, palette, plte, trns) catch return Failure.Damaged;
    decode.unpackRows(cb, file, raw) catch |failure| return switch (failure) {
        error.NoMemory => Failure.NoMemory,
        else => Failure.Damaged,
    };
    if (info.interlace == 0) {
        return pass(info, palette, raw, empty, colour, canvas, .{ 0, 0, 1, 1 }, info.width, info.height);
    }
    var offset: usize = 0;
    for (0..decode.passes.len) |nth| {
        const size = decode.passSize(info, nth);
        if (size.width == 0 or size.height == 0) continue;
        const bytes = @as(usize, size.height) * (1 + info.rowBytes(size.width));
        try pass(info, palette, raw[offset..][0..bytes], empty, colour, canvas, decode.passes[nth], size.width, size.height);
        offset += bytes;
    }
}

/// One pass of a PNG file's rows: each undone against the one above it,
/// read as colour and put at its place in `canvas`. `where` is where the
/// pass starts and how far apart its pixels are, across and down.
fn pass(info: decode.Info, palette: *const decode.Palette, raw: []u8, empty: []const u8, colour: []u8, canvas: []u8, where: [4]u32, width: u32, height: u32) Failure!void {
    const stride = info.rowBytes(width);
    const pixel = info.pixelBytes();
    const pitch = @as(usize, info.width) * 4;
    var above: []const u8 = empty[0..stride];
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const at = @as(usize, y) * (1 + stride);
        const row = raw[at + 1 ..][0..stride];
        decode.unfilter(raw[at], row, above, pixel) catch return Failure.Damaged;
        const line = canvas[(where[1] + y * where[3]) * pitch ..][0..pitch];
        if (where[2] == 1) {
            decode.expand(info, palette, row, width, line[where[0] * 4 ..][0 .. width * 4]);
        } else {
            decode.expand(info, palette, row, width, colour[0 .. width * 4]);
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const left = (where[0] + x * where[2]) * 4;
                @memcpy(line[left..][0..4], colour[x * 4 ..][0..4]);
            }
        }
        above = row;
    }
}

/// The picture on `canvas` scaled into the box `placed`: every pixel of
/// the box the mean of the picture over the pixel's area, what of the
/// area the picture does not reach counting as nothing. Coverage (a byte
/// a pixel, 0 to 255) comes out a byte a pixel, 0 to 15; colour (four
/// bytes) comes out four, its red, green and blue the mean weighted by
/// coverage, and 0 where nothing covers.
fn scaled(comptime colour: bool, canvas: []const u8, m: _strike.Metrics, placed: Placed, out: [*]u8) void {
    const each: usize = if (colour) 4 else 1;
    const per_x = 1.0 / placed.across;
    const per_y = 1.0 / placed.down;
    const area = per_x * per_y;
    const width: f32 = @floatFromInt(m.width);
    const rows: f32 = @floatFromInt(m.rows);
    for (0..placed.rows) |y| {
        // The pixel's rows of the picture, cut to it.
        const top = @max((@as(f32, @floatFromInt(y)) - placed.y) * per_y, 0);
        const bottom = @min((@as(f32, @floatFromInt(y + 1)) - placed.y) * per_y, rows);
        for (0..placed.width) |x| {
            const left = @max((@as(f32, @floatFromInt(x)) - placed.x) * per_x, 0);
            const right = @min((@as(f32, @floatFromInt(x + 1)) - placed.x) * per_x, width);
            var cover: f32 = 0;
            var sums = [3]f32{ 0, 0, 0 };
            if (bottom > top and right > left) {
                var row: u32 = @intFromFloat(top);
                while (row < m.rows and @as(f32, @floatFromInt(row)) < bottom) : (row += 1) {
                    const from: f32 = @floatFromInt(row);
                    const tall = @min(bottom, from + 1) - @max(top, from);
                    var column: u32 = @intFromFloat(left);
                    while (column < m.width and @as(f32, @floatFromInt(column)) < right) : (column += 1) {
                        const start: f32 = @floatFromInt(column);
                        const share = tall * (@min(right, start + 1) - @max(left, start));
                        const at = (@as(usize, row) * m.width + column) * each;
                        if (colour) {
                            const weight = share * @as(f32, @floatFromInt(canvas[at + 3]));
                            cover += weight;
                            for (0..3) |channel| sums[channel] += weight * @as(f32, @floatFromInt(canvas[at + channel]));
                        } else {
                            cover += share * @as(f32, @floatFromInt(canvas[at]));
                        }
                    }
                }
            }
            const into = out + (y * placed.width + x) * each;
            const mean = @min(cover / area, 255);
            if (colour) {
                for (0..3) |channel| {
                    into[channel] = if (cover > 0) @intFromFloat(@min(sums[channel] / cover + 0.5, 255)) else 0;
                }
                into[3] = @intFromFloat(mean + 0.5);
            } else {
                into[0] = @intFromFloat(mean * (15.0 / 255.0) + 0.5);
            }
        }
    }
}
