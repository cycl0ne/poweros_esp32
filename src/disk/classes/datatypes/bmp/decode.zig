// SPDX-License-Identifier: MIT
//! What a Windows bitmap says, and how its rows become colour.
//!
//! A file is a short header saying where the pixels are, then a
//! description of the picture, then the palette, then the rows. The rows
//! are written from the bottom up unless the picture says its height the
//! other way round, and each one is padded to a whole four bytes.
//!
//! **Numbers are low byte first**, which is the one thing that tells the
//! format apart from every other one read here.
//!
//! Pixels are one, four or eight bits into a palette, sixteen or
//! thirty-two bits in channels the file itself places, or twenty-four
//! bits of blue, green and red in that order. Palette rows may be packed
//! as runs (`RLE8`, `RLE4`), which is the only compression the format
//! ever had.

pub const Error = error{
    /// It does not begin the way a bitmap does.
    NotBmp,
    /// It does, and then says something the format does not allow.
    Corrupt,
    /// Something the format allows and this decoder does not.
    Unsupported,
};

/// How the rows are packed.
pub const BI_RGB: u32 = 0;
pub const BI_RLE8: u32 = 1;
pub const BI_RLE4: u32 = 2;
pub const BI_BITFIELDS: u32 = 3;

/// Where one channel sits in a pixel's word.
pub const Channel = struct {
    /// How far up the word it starts, and how many bits it is.
    shift: u5 = 0,
    bits: u5 = 0,

    /// The channel's value out of a pixel's word, as a number from 0 to
    /// 255. The bits are spread over the range, so that all-ones comes
    /// back as 0xFF.
    pub fn of(self: Channel, pixel: u32) u8 {
        if (self.bits == 0) return 0xFF;
        const value = (pixel >> self.shift) & ((@as(u32, 1) << self.bits) - 1);
        if (self.bits >= 8) return @truncate(value >> (self.bits - 8));
        var spread = value;
        var filled: u5 = self.bits;
        while (filled < 8) : (filled += self.bits) spread = (spread << self.bits) | value;
        return @truncate(spread >> (filled - 8));
    }
};

/// A channel from the mask a file gives for it.
pub fn channelOf(mask: u32) Channel {
    if (mask == 0) return .{};
    var shift: u5 = 0;
    while (shift < 31 and (mask >> shift) & 1 == 0) shift += 1;
    var bits: u5 = 0;
    while (bits < 31 and (mask >> (shift + bits)) & 1 != 0) bits += 1;
    return .{ .shift = shift, .bits = bits };
}

/// What the file says its picture is.
pub const Info = struct {
    width: u32 = 0,
    height: u32 = 0,
    bits: u32 = 0,
    compression: u32 = BI_RGB,
    /// The rows are written from the top down, which a negative height
    /// is what says.
    top_down: bool = false,
    /// Where the palette is and how many colours it holds, and how many
    /// bytes one of its entries takes.
    palette_at: usize = 0,
    palette_count: u32 = 0,
    palette_step: u32 = 4,
    /// Where the rows start.
    pixels_at: usize = 0,
    /// Where each channel sits, for the depths that place them.
    red: Channel = .{},
    green: Channel = .{},
    blue: Channel = .{},
    alpha: Channel = .{},

    /// Bytes a row takes, padded to a whole four.
    pub fn rowBytes(self: Info) u32 {
        return ((self.width * self.bits + 31) / 32) * 4;
    }
};

fn word(from: []const u8) u32 {
    return @as(u32, from[0]) | @as(u32, from[1]) << 8 |
        @as(u32, from[2]) << 16 | @as(u32, from[3]) << 24;
}

fn half(from: []const u8) u32 {
    return @as(u32, from[0]) | @as(u32, from[1]) << 8;
}

/// The file read as far as its rows.
pub fn readInfo(file: []const u8) Error!Info {
    if (file.len < 18) return Error.NotBmp;
    if (file[0] != 'B' or file[1] != 'M') return Error.NotBmp;
    const pixels_at = word(file[10..]);
    const header_size = word(file[14..]);
    if (18 + header_size > file.len) return Error.Corrupt;

    var info = Info{ .pixels_at = pixels_at };
    // The first description the format had is twelve bytes and its
    // palette holds three bytes a colour; everything since is forty or
    // more and holds four.
    if (header_size == 12) {
        if (file.len < 26) return Error.Corrupt;
        info.width = half(file[18..]);
        info.height = half(file[20..]);
        info.bits = half(file[24..]);
        info.palette_step = 3;
        info.palette_at = 26;
    } else if (header_size >= 40) {
        if (file.len < 14 + header_size) return Error.Corrupt;
        const height: i32 = @bitCast(word(file[22..]));
        info.width = word(file[18..]);
        info.height = @abs(height);
        info.top_down = height < 0;
        info.bits = half(file[28..]);
        info.compression = word(file[30..]);
        info.palette_count = word(file[46..]);
        info.palette_at = 14 + header_size;
        // The three or four masks a file may place its channels with,
        // which follow the description or are in it.
        if (info.compression == BI_BITFIELDS) {
            const at: usize = if (header_size >= 56) 14 + 40 else 14 + header_size;
            if (at + 12 > file.len) return Error.Corrupt;
            info.red = channelOf(word(file[at..]));
            info.green = channelOf(word(file[at + 4 ..]));
            info.blue = channelOf(word(file[at + 8 ..]));
            if (header_size >= 56 and at + 16 <= file.len) info.alpha = channelOf(word(file[at + 12 ..]));
            if (header_size < 56) info.palette_at = at + 12;
        }
    } else {
        return Error.Unsupported;
    }

    if (info.width == 0 or info.height == 0) return Error.Corrupt;
    switch (info.bits) {
        1, 4, 8, 16, 24, 32 => {},
        else => return Error.Unsupported,
    }
    if (info.compression == BI_RLE8 and info.bits != 8) return Error.Corrupt;
    if (info.compression == BI_RLE4 and info.bits != 4) return Error.Corrupt;
    if (info.compression > BI_BITFIELDS) return Error.Unsupported;

    // Where the channels sit when the file does not say: the shapes the
    // format settled on.
    if (info.compression != BI_BITFIELDS) {
        if (info.bits == 16) {
            info.red = .{ .shift = 10, .bits = 5 };
            info.green = .{ .shift = 5, .bits = 5 };
            info.blue = .{ .shift = 0, .bits = 5 };
        } else if (info.bits == 32) {
            info.red = .{ .shift = 16, .bits = 8 };
            info.green = .{ .shift = 8, .bits = 8 };
            info.blue = .{ .shift = 0, .bits = 8 };
        }
    }
    if (info.bits <= 8) {
        const most = @as(u32, 1) << @truncate(info.bits);
        if (info.palette_count == 0 or info.palette_count > most) info.palette_count = most;
    }
    if (info.pixels_at == 0 or info.pixels_at >= file.len) return Error.Corrupt;
    return info;
}

/// A colour of the palette, as red, green, blue and coverage. The file
/// holds them blue first.
pub fn colorOf(file: []const u8, info: Info, index: u32, into: []u8) void {
    const at = info.palette_at + index * info.palette_step;
    if (index >= info.palette_count or at + 3 > file.len) {
        into[0] = 0;
        into[1] = 0;
        into[2] = 0;
        into[3] = 0xFF;
        return;
    }
    into[0] = file[at + 2];
    into[1] = file[at + 1];
    into[2] = file[at];
    into[3] = 0xFF;
}

/// The number a pixel of a palette row holds.
pub fn indexAt(row: []const u8, x: u32, bits: u32) u32 {
    return switch (bits) {
        8 => row[x],
        4 => (row[x / 2] >> @truncate(4 - 4 * (x & 1))) & 0x0F,
        else => (row[x / 8] >> @truncate(7 - (x & 7))) & 1,
    };
}

/// One row of the file read as red, green, blue and coverage.
pub fn expandRow(file: []const u8, info: Info, row: []const u8, into: []u8) void {
    var x: u32 = 0;
    while (x < info.width) : (x += 1) {
        const at = into[x * 4 ..];
        switch (info.bits) {
            24 => {
                const from = row[x * 3 ..];
                at[0] = from[2];
                at[1] = from[1];
                at[2] = from[0];
                at[3] = 0xFF;
            },
            32, 16 => {
                const value: u32 = if (info.bits == 32) word(row[x * 4 ..]) else half(row[x * 2 ..]);
                at[0] = info.red.of(value);
                at[1] = info.green.of(value);
                at[2] = info.blue.of(value);
                // A file with no alpha mask is solid, whatever the bits
                // it does not use happen to hold.
                at[3] = if (info.alpha.bits == 0) 0xFF else info.alpha.of(value);
            },
            else => colorOf(file, info, indexAt(row, x, info.bits), at),
        }
    }
}

/// Packed palette rows unpacked into one number a pixel, laid out from
/// the top down. False when the file runs out mid-run.
///
/// A run is a count and a colour, or a count of zero and a word that
/// says what else: the end of a row, the end of the picture, a jump, or
/// that many pixels written out as they stand.
pub fn unpackRuns(file: []const u8, info: Info, into: []u8) bool {
    @memset(into, 0);
    const four = info.compression == BI_RLE4;
    var at = info.pixels_at;
    var x: u32 = 0;
    var y: u32 = 0;
    while (at + 1 < file.len) {
        const count = file[at];
        const what = file[at + 1];
        at += 2;
        if (count != 0) {
            var n: u32 = 0;
            while (n < count) : (n += 1) {
                const value: u8 = if (!four) what else if (n & 1 == 0) what >> 4 else what & 0x0F;
                put(info, into, x, y, value);
                x += 1;
            }
            continue;
        }
        switch (what) {
            0 => {
                x = 0;
                y += 1;
            },
            1 => return true,
            2 => {
                if (at + 2 > file.len) return false;
                x += file[at];
                y += file[at + 1];
                at += 2;
            },
            else => {
                const run: u32 = what;
                const bytes: usize = if (four) (run + 1) / 2 else run;
                if (at + bytes > file.len) return false;
                var n: u32 = 0;
                while (n < run) : (n += 1) {
                    const value: u8 = if (!four)
                        file[at + n]
                    else if (n & 1 == 0)
                        file[at + n / 2] >> 4
                    else
                        file[at + n / 2] & 0x0F;
                    put(info, into, x, y, value);
                    x += 1;
                }
                // A run of bytes is padded to a whole word.
                at += bytes + (bytes & 1);
            },
        }
    }
    return true;
}

/// One pixel of an unpacked row, ignored when it falls outside the
/// picture: a file may say a jump that goes too far.
fn put(info: Info, into: []u8, x: u32, y: u32, value: u8) void {
    if (x >= info.width or y >= info.height) return;
    // Packed rows are written from the bottom up, as every other row is.
    const row = info.height - 1 - y;
    into[row * info.width + x] = value;
}

const std = @import("std");
const testing = std.testing;

test "a header read, and what is not one" {
    // A 4x2 picture of eight bits into a palette of four.
    var file: [14 + 40 + 16 + 8]u8 = @splat(0);
    file[0] = 'B';
    file[1] = 'M';
    file[10] = 14 + 40 + 16; // where the rows start
    file[14] = 40; // the description's size
    file[18] = 4; // width
    file[22] = 2; // height
    file[28] = 8; // bits a pixel
    file[46] = 4; // colours
    const info = try readInfo(&file);
    try testing.expectEqual(@as(u32, 4), info.width);
    try testing.expectEqual(@as(u32, 2), info.height);
    try testing.expectEqual(@as(u32, 4), info.rowBytes());
    try testing.expect(!info.top_down);

    var wrong = file;
    wrong[1] = 'N';
    try testing.expectError(Error.NotBmp, readInfo(&wrong));
}

test "a channel is spread over the whole range" {
    const five = Channel{ .shift = 0, .bits = 5 };
    try testing.expectEqual(@as(u8, 0), five.of(0));
    try testing.expectEqual(@as(u8, 0xFF), five.of(31));
    const eight = Channel{ .shift = 8, .bits = 8 };
    try testing.expectEqual(@as(u8, 0x7F), eight.of(0x7F00));
}

test "a mask says where a channel sits" {
    const c = channelOf(0x00FF_0000);
    try testing.expectEqual(@as(u5, 16), c.shift);
    try testing.expectEqual(@as(u5, 8), c.bits);
    try testing.expectEqual(@as(u5, 0), channelOf(0).bits);
}

test "a number is taken out of a row at any depth" {
    const row = [_]u8{ 0b1010_0000, 0x12, 0x34 };
    try testing.expectEqual(@as(u32, 1), indexAt(&row, 0, 1));
    try testing.expectEqual(@as(u32, 0), indexAt(&row, 1, 1));
    try testing.expectEqual(@as(u32, 0b1010), indexAt(&row, 0, 4));
    try testing.expectEqual(@as(u32, 0x12), indexAt(&row, 1, 8));
}

test "packed runs come back as the rows they stand for" {
    // Two rows of four pixels: a run of four, then four written out.
    var file: [14 + 40 + 16 + 16]u8 = @splat(0);
    file[0] = 'B';
    file[1] = 'M';
    file[10] = 14 + 40 + 16;
    file[14] = 40;
    file[18] = 4;
    file[22] = 2;
    file[28] = 8;
    file[30] = @intCast(BI_RLE8);
    file[46] = 4;
    const at: usize = 14 + 40 + 16;
    file[at] = 4; // four of
    file[at + 1] = 2; // colour two
    file[at + 2] = 0; // the row ends
    file[at + 3] = 0;
    file[at + 4] = 0; // as they stand
    file[at + 5] = 4;
    file[at + 6] = 1;
    file[at + 7] = 1;
    file[at + 8] = 3;
    file[at + 9] = 3;
    file[at + 10] = 0; // the picture ends
    file[at + 11] = 1;

    const info = try readInfo(&file);
    var into: [8]u8 = undefined;
    try testing.expect(unpackRuns(&file, info, &into));
    // The first row of the file is the bottom row of the picture.
    try testing.expectEqualSlices(u8, &.{ 1, 1, 3, 3 }, into[0..4]);
    try testing.expectEqualSlices(u8, &.{ 2, 2, 2, 2 }, into[4..8]);
}
