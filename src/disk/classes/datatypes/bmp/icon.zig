// SPDX-License-Identifier: MIT
//! What a Windows icon file holds, and how one of its pictures is read.
//!
//! A file is a directory of the same picture at several sizes and depths:
//! six bytes - two of nothing, the kind (1, an icon), how many - then
//! sixteen bytes for each picture: its width and its height (0 for 256),
//! how many colours its palette has, its depth, how long it is and where
//! it starts. **A picture is a whole PNG file, or a bitmap** without the
//! file header a `.bmp` has. A bitmap's description says twice its
//! height: the colour rows, from the bottom up as a `.bmp`'s, are
//! followed by as many rows of a mask, one bit a pixel, set where the
//! picture is clear. A picture of 32 bits carries its coverage in its
//! fourth byte as well, unless that byte is nought throughout.
//!
//! `count` reads the directory's head, `pick` the picture to show - the
//! largest, the deepest of the largest - and `readBitmap` a bitmap's
//! description into decode.zig's `Info`, so that its rows become colour
//! by `decode.expandRow`; `clearAt` reads its mask. Numbers are low byte
//! first. Nothing here opens anything: the host tests hold all of it.

const decode = @import("decode.zig");

pub const Error = error{
    /// It does not begin the way an icon file does.
    NotIcon,
    /// It does, and then says something the format does not allow.
    Corrupt,
    /// Something the format allows and this reader does not.
    Unsupported,
};

/// One picture of the directory.
pub const Entry = struct {
    width: u32,
    height: u32,
    bits: u32,
    /// Where in the file it lies, and how long it is.
    at: u32,
    length: u32,
};

/// How many pictures the file's directory holds, every entry inside the
/// file.
pub fn count(file: []const u8) Error!u32 {
    if (file.len < 6) return Error.NotIcon;
    if (half(file[0..]) != 0 or half(file[2..]) != 1) return Error.NotIcon;
    const pictures = half(file[4..]);
    if (pictures == 0) return Error.NotIcon;
    if (6 + 16 * @as(usize, pictures) > file.len) return Error.Corrupt;
    return pictures;
}

/// The directory's entry `index`, as it stands.
pub fn entryAt(file: []const u8, index: u32) Entry {
    const at = file[6 + 16 * @as(usize, index) ..];
    return .{
        .width = if (at[0] == 0) 256 else at[0],
        .height = if (at[1] == 0) 256 else at[1],
        .bits = half(at[6..]),
        .length = word(at[8..]),
        .at = word(at[12..]),
    };
}

/// The picture to show: the largest of those that lie inside the file,
/// and of the largest the deepest.
pub fn pick(file: []const u8, pictures: u32) Error!Entry {
    var best: ?Entry = null;
    var index: u32 = 0;
    while (index < pictures) : (index += 1) {
        const entry = entryAt(file, index);
        if (entry.length == 0 or entry.at < 6 + 16 * pictures) continue;
        if (@as(usize, entry.at) + entry.length > file.len) continue;
        if (best) |chosen| {
            const area = entry.width * entry.height;
            const chosen_area = chosen.width * chosen.height;
            if (area < chosen_area or (area == chosen_area and entry.bits <= chosen.bits)) continue;
        }
        best = entry;
    }
    return best orelse Error.Corrupt;
}

/// Whether a picture is a whole PNG file.
pub fn isPng(image: []const u8) bool {
    const signature = "\x89PNG\x0d\x0a\x1a\x0a";
    if (image.len < signature.len) return false;
    for (image[0..signature.len], signature) |got, want| {
        if (got != want) return false;
    }
    return true;
}

/// A bitmap picture: its description as a `.bmp`'s is read, and where
/// its mask is - `mask_at` 0 when the picture has none.
pub const Bitmap = struct {
    info: decode.Info,
    mask_at: usize = 0,
    mask_row: u32 = 0,
    /// Whether its fourth bytes say its coverage.
    alpha: bool = false,
};

/// A bitmap picture's description read.
pub fn readBitmap(image: []const u8) Error!Bitmap {
    if (image.len < 40) return Error.Corrupt;
    const header_size = word(image[0..]);
    if (header_size < 40 or header_size > image.len) return Error.Corrupt;
    const twice: i32 = @bitCast(word(image[8..]));
    if (twice <= 0) return Error.Corrupt;
    var info = decode.Info{
        .width = word(image[4..]),
        .height = @as(u32, @intCast(twice)) / 2,
        .bits = half(image[14..]),
        .compression = word(image[16..]),
        .palette_at = header_size,
        .palette_count = word(image[32..]),
    };
    if (info.width == 0 or info.height == 0 or info.width > 1024 or info.height > 1024) return Error.Corrupt;
    if (info.compression != decode.BI_RGB) return Error.Unsupported;
    switch (info.bits) {
        1, 4, 8, 24, 32 => {},
        else => return Error.Unsupported,
    }
    var palette_bytes: usize = 0;
    if (info.bits <= 8) {
        const most = @as(u32, 1) << @truncate(info.bits);
        if (info.palette_count == 0 or info.palette_count > most) info.palette_count = most;
        palette_bytes = @as(usize, info.palette_count) * 4;
    }
    if (info.bits == 32) {
        info.red = .{ .shift = 16, .bits = 8 };
        info.green = .{ .shift = 8, .bits = 8 };
        info.blue = .{ .shift = 0, .bits = 8 };
    }
    info.pixels_at = header_size + palette_bytes;
    const rows_end = info.pixels_at + @as(usize, info.rowBytes()) * info.height;
    if (rows_end > image.len) return Error.Corrupt;

    var bitmap = Bitmap{ .info = info };
    const mask_row = ((info.width + 31) / 32) * 4;
    if (rows_end + @as(usize, mask_row) * info.height <= image.len) {
        bitmap.mask_at = rows_end;
        bitmap.mask_row = mask_row;
    }
    if (info.bits == 32 and hasCoverage(image, info)) {
        bitmap.alpha = true;
        bitmap.info.alpha = .{ .shift = 24, .bits = 8 };
    }
    return bitmap;
}

/// Whether a picture of 32 bits says its coverage: a fourth byte that is
/// not nought somewhere.
fn hasCoverage(image: []const u8, info: decode.Info) bool {
    const rows = image[info.pixels_at..][0 .. @as(usize, info.rowBytes()) * info.height];
    var at: usize = 3;
    while (at < rows.len) : (at += 4) {
        if (rows[at] != 0) return true;
    }
    return false;
}

/// Whether the mask says the pixel at `x` of the file's row `row` - the
/// rows from the bottom up - is clear.
pub fn clearAt(image: []const u8, bitmap: Bitmap, x: u32, row: u32) bool {
    if (bitmap.mask_at == 0) return false;
    const at = bitmap.mask_at + @as(usize, row) * bitmap.mask_row + x / 8;
    return (image[at] >> @truncate(7 - (x & 7))) & 1 != 0;
}

fn word(from: []const u8) u32 {
    return @as(u32, from[0]) | @as(u32, from[1]) << 8 |
        @as(u32, from[2]) << 16 | @as(u32, from[3]) << 24;
}

fn half(from: []const u8) u32 {
    return @as(u32, from[0]) | @as(u32, from[1]) << 8;
}

const std = @import("std");
const testing = std.testing;

/// An icon of two pictures: a 2x2 bitmap of four colours into a palette,
/// its mask clearing one pixel, and a "PNG" of 16x16 that is only its
/// signature and so is never decoded here.
fn sample() [6 + 32 + 40 + 16 + 8 + 8 + 8]u8 {
    var file: [6 + 32 + 40 + 16 + 8 + 8 + 8]u8 = @splat(0);
    file[2] = 1; // an icon
    file[4] = 2; // two pictures
    const bitmap_at: u32 = 6 + 32;
    const bitmap_length: u32 = 40 + 16 + 8 + 8;
    const png_at: u32 = bitmap_at + bitmap_length;
    // The bitmap's entry: 2x2, 8 bits.
    file[6] = 2;
    file[7] = 2;
    file[6 + 6] = 8;
    file[6 + 8] = @intCast(bitmap_length);
    file[6 + 12] = @intCast(bitmap_at);
    // The PNG's entry: 16x16, 32 bits.
    file[22] = 16;
    file[23] = 16;
    file[22 + 6] = 32;
    file[22 + 8] = 8;
    file[22 + 12] = @intCast(png_at);
    // The bitmap: its description, twice its height.
    const b = file[bitmap_at..];
    b[0] = 40;
    b[4] = 2;
    b[8] = 4;
    b[12] = 1;
    b[14] = 8;
    b[32] = 4;
    // Four colours, blue first: red, green, blue, white.
    const palette = [_]u8{ 0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0 };
    @memcpy(b[40..][0..16], &palette);
    // The rows, from the bottom up, each padded to four: 2 3, then 0 1.
    b[56] = 2;
    b[57] = 3;
    b[60] = 0;
    b[61] = 1;
    // The mask, from the bottom up: the bottom row's second pixel clear.
    b[64] = 0b0100_0000;
    @memcpy(file[png_at..][0..8], "\x89PNG\x0d\x0a\x1a\x0a");
    return file;
}

test "an icon's directory read, and what is not one" {
    var file = sample();
    try testing.expectEqual(@as(u32, 2), try count(&file));
    const first = entryAt(&file, 0);
    try testing.expectEqual(@as(u32, 2), first.width);
    try testing.expectEqual(@as(u32, 8), first.bits);
    // The larger is picked, whatever its place.
    const chosen = try pick(&file, 2);
    try testing.expectEqual(@as(u32, 16), chosen.width);
    try testing.expect(isPng(file[chosen.at..][0..chosen.length]));

    var cursor = file;
    cursor[2] = 2;
    try testing.expectError(Error.NotIcon, count(&cursor));
    try testing.expectError(Error.NotIcon, count(file[0..4]));
    var short = file;
    short[4] = 9;
    try testing.expectError(Error.Corrupt, count(&short));
    // A picture past the file's end is passed over.
    var beyond = file;
    beyond[22 + 12] = 250;
    try testing.expectEqual(@as(u32, 2), (try pick(&beyond, 2)).width);
}

test "an icon's bitmap: its colours from the palette, its mask clear" {
    var file = sample();
    const entry = entryAt(&file, 0);
    const image = file[entry.at..][0..entry.length];
    try testing.expect(!isPng(image));
    const bitmap = try readBitmap(image);
    try testing.expectEqual(@as(u32, 2), bitmap.info.width);
    try testing.expectEqual(@as(u32, 2), bitmap.info.height);
    try testing.expect(!bitmap.alpha);
    // The file's last row is the picture's first: red and green.
    var colour: [8]u8 = undefined;
    const row = image[bitmap.info.pixels_at + bitmap.info.rowBytes() ..][0..bitmap.info.rowBytes()];
    decode.expandRow(image, bitmap.info, row, &colour);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255 }, &colour);
    try testing.expect(!clearAt(image, bitmap, 0, 0));
    try testing.expect(clearAt(image, bitmap, 1, 0));
    try testing.expect(!clearAt(image, bitmap, 1, 1));
}

test "a bitmap of 32 bits says its coverage, unless its fourth bytes are nought" {
    var image: [40 + 8 + 8]u8 = @splat(0);
    image[0] = 40;
    image[4] = 1;
    image[8] = 4;
    image[14] = 32;
    const solid = try readBitmap(&image);
    try testing.expect(!solid.alpha);
    image[40 + 3] = 0x80;
    const covered = try readBitmap(&image);
    try testing.expect(covered.alpha);
    try testing.expectEqual(@as(u5, 24), covered.info.alpha.shift);
    image[16] = 1; // packed rows
    try testing.expectError(Error.Unsupported, readBitmap(&image));
}
