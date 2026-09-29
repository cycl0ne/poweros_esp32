// SPDX-License-Identifier: MIT
//! What a GIF file says: the screen it describes, its colours and where
//! its first picture is.
//!
//! A file is a signature, a description of the screen the pictures are
//! meant to be placed on, a palette for all of them, and then a run of
//! blocks: a picture, an extension that says something about the picture
//! after it, or the end. A picture has a place and a size of its own
//! inside that screen, may bring a palette of its own, and its pixels
//! are numbers into whichever palette applies, compressed.
//!
//! **What is shown is the screen, not the first picture.** A file whose
//! picture is smaller than the screen it names is meant to be seen with
//! that much room round it, and an animation's frames only make sense
//! against it. What is not covered is the background colour, or nothing
//! at all where the file names a colour that stands for nothing.
//!
//! Numbers are two bytes, low byte first.

pub const Error = error{
    /// It does not begin the way a GIF does.
    NotGif,
    /// It does, and then says something the format does not allow.
    Corrupt,
};

/// How many colours a palette can hold.
pub const max_colors = 256;

/// The blocks a file is made of.
pub const block_image: u8 = 0x2C;
pub const block_extension: u8 = 0x21;
pub const block_end: u8 = 0x3B;

/// The extensions that matter here.
pub const ext_graphic_control: u8 = 0xF9;

/// What the file says about the screen its pictures sit on.
pub const Screen = struct {
    width: u32 = 0,
    height: u32 = 0,
    /// Which colour of the palette the parts no picture covers are.
    background: u8 = 0,
    /// Where the palette is in the file, and how many colours it holds;
    /// empty when the file has none of its own.
    palette: []const u8 = &.{},
    /// Where the blocks start.
    at: usize = 0,
};

/// What one picture in the file says about itself.
pub const Picture = struct {
    left: u32 = 0,
    top: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// Its rows are written in four passes.
    interlace: bool = false,
    /// Its own palette, or the screen's when it brings none.
    palette: []const u8 = &.{},
    /// The colour that stands for nothing, when the file names one.
    transparent: ?u8 = null,
    /// How many bits the first codes of its compressed pixels take.
    min_code_size: u8 = 0,
    /// Where the blocks its compressed pixels are written in start.
    data_at: usize = 0,
};

/// A two-byte number as the file holds it, low byte first.
pub fn half(from: []const u8) u32 {
    return @as(u32, from[0]) | @as(u32, from[1]) << 8;
}

/// The screen the file describes, and where its blocks start.
pub fn readScreen(file: []const u8) Error!Screen {
    if (file.len < 13) return Error.NotGif;
    if (file[0] != 'G' or file[1] != 'I' or file[2] != 'F') return Error.NotGif;
    if (file[3] != '8' or file[5] != 'a') return Error.NotGif;
    if (file[4] != '7' and file[4] != '9') return Error.NotGif;

    var screen = Screen{
        .width = half(file[6..]),
        .height = half(file[8..]),
        .background = file[11],
        .at = 13,
    };
    if (screen.width == 0 or screen.height == 0) return Error.Corrupt;
    const packed_byte = file[10];
    if (packed_byte & 0x80 != 0) {
        const colors = @as(usize, 2) << @truncate(packed_byte & 7);
        if (13 + colors * 3 > file.len) return Error.Corrupt;
        screen.palette = file[13..][0 .. colors * 3];
        screen.at = 13 + colors * 3;
    }
    return screen;
}

/// The first picture in the file, with whatever the extensions before it
/// said about it. Null when the file holds none.
pub fn readFirst(file: []const u8, screen: Screen) Error!?Picture {
    var at = screen.at;
    var transparent: ?u8 = null;
    while (at < file.len) {
        switch (file[at]) {
            block_end => return null,
            block_extension => {
                if (at + 2 > file.len) return Error.Corrupt;
                const kind = file[at + 1];
                const walk = at + 2;
                // A graphic control block says whether one of the
                // colours stands for nothing; it applies to the picture
                // that follows it.
                if (kind == ext_graphic_control and walk < file.len and file[walk] >= 4) {
                    if (walk + 5 > file.len) return Error.Corrupt;
                    if (file[walk + 1] & 1 != 0) transparent = file[walk + 4];
                }
                at = try skipBlocks(file, walk);
            },
            block_image => {
                if (at + 10 > file.len) return Error.Corrupt;
                var picture = Picture{
                    .left = half(file[at + 1 ..]),
                    .top = half(file[at + 3 ..]),
                    .width = half(file[at + 5 ..]),
                    .height = half(file[at + 7 ..]),
                    .interlace = file[at + 9] & 0x40 != 0,
                    .palette = screen.palette,
                    .transparent = transparent,
                };
                var walk = at + 10;
                if (file[at + 9] & 0x80 != 0) {
                    const colors = @as(usize, 2) << @truncate(file[at + 9] & 7);
                    if (walk + colors * 3 > file.len) return Error.Corrupt;
                    picture.palette = file[walk..][0 .. colors * 3];
                    walk += colors * 3;
                }
                if (walk >= file.len) return Error.Corrupt;
                picture.min_code_size = file[walk];
                picture.data_at = walk + 1;
                if (picture.width == 0 or picture.height == 0) return Error.Corrupt;
                if (picture.palette.len == 0) return Error.Corrupt;
                return picture;
            },
            else => return Error.Corrupt,
        }
    }
    return Error.Corrupt;
}

/// Past a run of blocks, each a length byte and that many bytes, ending
/// in a length of nothing.
pub fn skipBlocks(file: []const u8, from: usize) Error!usize {
    var at = from;
    while (at < file.len) {
        const length = file[at];
        at += 1;
        if (length == 0) return at;
        at += length;
    }
    return Error.Corrupt;
}

/// How many bytes a run of blocks holds when its pieces are joined.
pub fn blockBytes(file: []const u8, from: usize) Error!usize {
    var at = from;
    var total: usize = 0;
    while (at < file.len) {
        const length = file[at];
        at += 1;
        if (length == 0) return total;
        if (at + length > file.len) return Error.Corrupt;
        total += length;
        at += length;
    }
    return Error.Corrupt;
}

/// The pieces of a run of blocks copied one after another into `into`.
pub fn gatherBlocks(file: []const u8, from: usize, into: []u8) usize {
    var at = from;
    var done: usize = 0;
    while (at < file.len) {
        const length = file[at];
        at += 1;
        if (length == 0) break;
        if (at + length > file.len or done + length > into.len) break;
        @memcpy(into[done..][0..length], file[at..][0..length]);
        done += length;
        at += length;
    }
    return done;
}

/// Where the pixels of a picture's four passes start, and how far apart
/// the rows of each are.
pub const passes = [4][2]u32{ .{ 0, 8 }, .{ 4, 8 }, .{ 2, 4 }, .{ 1, 2 } };

/// Which row of the picture the `n`th row of its pixels is.
pub fn rowOf(picture: Picture, n: u32) u32 {
    if (!picture.interlace) return n;
    var left = n;
    for (passes) |pass| {
        const start = pass[0];
        const step = pass[1];
        const rows = if (picture.height > start) (picture.height - start + step - 1) / step else 0;
        if (left < rows) return start + left * step;
        left -= rows;
    }
    return picture.height - 1;
}

const std = @import("std");
const testing = std.testing;

test "a screen and the picture on it" {
    // The smallest file a coder writes: a screen, four colours, one
    // picture that covers it.
    const file = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        8, 0, 2, 0, // eight across, two down
        0x81, 0,   0, // a palette of four, background 0
        0,    0,   0,
        255,  0,   0,
        0,    255, 0,
        0,    0,   255,
        0x2C, 0, 0, 0, 0, 8, 0, 2, 0, 0, // the picture
        8, // eight bits a code
        1,    0x00, 0, // one byte of pixels, then the end
        0x3B,
    };
    const screen = try readScreen(&file);
    try testing.expectEqual(@as(u32, 8), screen.width);
    try testing.expectEqual(@as(usize, 12), screen.palette.len);
    const picture = (try readFirst(&file, screen)).?;
    try testing.expectEqual(@as(u32, 8), picture.width);
    try testing.expectEqual(@as(u8, 8), picture.min_code_size);
    try testing.expect(!picture.interlace);
    try testing.expect(picture.transparent == null);
}

test "what is not a GIF says so" {
    const file = [_]u8{ 'G', 'I', 'F', '8', '5', 'a', 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(Error.NotGif, readScreen(&file));
}

test "the four passes of an interlaced picture cover every row once" {
    const picture = Picture{ .width = 4, .height = 9, .interlace = true };
    var seen: [9]bool = @splat(false);
    for (0..9) |n| seen[rowOf(picture, @intCast(n))] = true;
    for (seen) |row| try testing.expect(row);
}
