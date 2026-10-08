// SPDX-License-Identifier: MIT
//! What a PNG file says, and how its rows become colour.
//!
//! A file is a signature and then chunks, each with its length, its four
//! characters, its bytes and a checksum. `IHDR` says how big the picture
//! is and what a pixel looks like, `PLTE` and `tRNS` give the palette and
//! what of it is see-through, and the `IDAT` chunks together are one
//! compressed stream. The stream unpacks into rows, each with a filter
//! byte in front of it saying how it was written down against the row
//! above; undoing that and then reading the pixels is all there is to it.
//!
//! **The checksum of every chunk is checked.** A picture decoded out of
//! a damaged file looks like a fault in the decoder, and the file
//! already carries what is needed to tell the two apart.
//!
//! A pixel comes out as four bytes - red, green, blue, coverage - in
//! every case, so that a picture of any depth and any colour kind is one
//! shape by the time it reaches picture.datatype. Sixteen bits a channel
//! are taken by their high byte: the screens have eight.
//!
//! png.datatype reads a picture with it, icon.library an icon.

const inflate = @import("inflate.zig");

pub const Error = error{
    /// It does not begin the way a PNG does.
    NotPng,
    /// It does, and then says something the format does not allow.
    Corrupt,
    /// Something the format allows and this decoder does not.
    Unsupported,
} || inflate.Error;

/// The eight bytes every file starts with: one high byte so that a
/// stream stripped to seven bits shows, then the name, then line ends
/// of both kinds so that a file translated between them shows too.
pub const signature = [8]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

pub const ID_IHDR = id("IHDR");
pub const ID_PLTE = id("PLTE");
pub const ID_IDAT = id("IDAT");
pub const ID_IEND = id("IEND");
pub const ID_TRNS = id("tRNS");

fn id(comptime text: *const [4]u8) u32 {
    return @as(u32, text[0]) << 24 | @as(u32, text[1]) << 16 |
        @as(u32, text[2]) << 8 | text[3];
}

/// What `IHDR` says.
pub const Info = struct {
    width: u32 = 0,
    height: u32 = 0,
    /// Bits a channel: 1, 2, 4, 8 or 16.
    depth: u8 = 8,
    /// 0 grey, 2 colour, 3 palette, 4 grey with coverage, 6 colour with
    /// coverage.
    color: u8 = 0,
    /// 1 when the rows are written in seven passes.
    interlace: u8 = 0,

    /// How many numbers a pixel is written as.
    pub fn channels(self: Info) u32 {
        return switch (self.color) {
            0, 3 => 1,
            2 => 3,
            4 => 2,
            6 => 4,
            else => 0,
        };
    }

    /// Bytes from one pixel to the next, at least one: what a filter
    /// counts back by.
    pub fn pixelBytes(self: Info) u32 {
        const bits = self.channels() * self.depth;
        return @max((bits + 7) / 8, 1);
    }

    /// Bytes a row of `width` pixels takes, without its filter byte.
    pub fn rowBytes(self: Info, width: u32) u32 {
        return (width * self.channels() * self.depth + 7) / 8;
    }

    /// Whether what the file holds carries coverage, so that the picture
    /// is drawn mixed into what is under it.
    pub fn hasAlpha(self: Info, transparent: bool) bool {
        return self.color == 4 or self.color == 6 or transparent;
    }
};

/// Where the seven passes of an interlaced file start and how far apart
/// their pixels are.
pub const passes = [7][4]u32{
    .{ 0, 0, 8, 8 },
    .{ 4, 0, 8, 8 },
    .{ 0, 4, 4, 8 },
    .{ 2, 0, 4, 4 },
    .{ 0, 2, 2, 4 },
    .{ 1, 0, 2, 2 },
    .{ 0, 1, 1, 2 },
};

/// How many pixels across and down one pass holds.
pub fn passSize(info: Info, pass: usize) struct { width: u32, height: u32 } {
    const start_x = passes[pass][0];
    const start_y = passes[pass][1];
    const step_x = passes[pass][2];
    const step_y = passes[pass][3];
    const width = if (info.width > start_x) (info.width - start_x + step_x - 1) / step_x else 0;
    const height = if (info.height > start_y) (info.height - start_y + step_y - 1) / step_y else 0;
    return .{ .width = width, .height = height };
}

// --- walking the chunks -----------------------------------------------------

/// One chunk: what it is called and what it holds.
pub const Chunk = struct {
    id: u32,
    data: []const u8,
};

/// A walk over a file's chunks, past the signature.
pub const Walk = struct {
    file: []const u8,
    at: usize = signature.len,

    pub fn start(file: []const u8) Error!Walk {
        if (file.len < signature.len) return Error.NotPng;
        for (signature, 0..) |byte, i| if (file[i] != byte) return Error.NotPng;
        return .{ .file = file };
    }

    /// The next chunk, or null at the end of the file. A chunk whose
    /// checksum does not match is an error.
    pub fn next(self: *Walk) Error!?Chunk {
        if (self.at == self.file.len) return null;
        if (self.at + 12 > self.file.len) return Error.Corrupt;
        const length = word(self.file[self.at..]);
        const kind = word(self.file[self.at + 4 ..]);
        if (self.at + 12 + length > self.file.len) return Error.Corrupt;
        const data = self.file[self.at + 8 ..][0..length];
        const said = word(self.file[self.at + 8 + length ..]);
        if (crc32(self.file[self.at + 4 ..][0 .. 4 + length]) != said) return Error.Corrupt;
        self.at += 12 + length;
        return .{ .id = kind, .data = data };
    }
};

/// A four-byte number as the file holds it, high byte first.
pub fn word(from: []const u8) u32 {
    return @as(u32, from[0]) << 24 | @as(u32, from[1]) << 16 |
        @as(u32, from[2]) << 8 | from[3];
}

/// What the file's `IHDR` says, and whether this decoder can read it.
pub fn readInfo(file: []const u8) Error!Info {
    var walk = try Walk.start(file);
    const first = try walk.next() orelse return Error.Corrupt;
    if (first.id != ID_IHDR or first.data.len != 13) return Error.Corrupt;
    const info = Info{
        .width = word(first.data[0..]),
        .height = word(first.data[4..]),
        .depth = first.data[8],
        .color = first.data[9],
        .interlace = first.data[12],
    };
    if (info.width == 0 or info.height == 0) return Error.Corrupt;
    // Only one way of compressing and one of filtering was ever defined.
    if (first.data[10] != 0 or first.data[11] != 0) return Error.Unsupported;
    if (info.interlace > 1) return Error.Unsupported;
    if (info.channels() == 0) return Error.Corrupt;
    switch (info.depth) {
        1, 2, 4 => if (info.color != 0 and info.color != 3) return Error.Corrupt,
        8, 16 => {},
        else => return Error.Corrupt,
    }
    if (info.depth == 16 and info.color == 3) return Error.Corrupt;
    return info;
}

/// How many bytes the unpacked stream holds: every row of every pass,
/// each with its filter byte.
pub fn rawSize(info: Info) usize {
    if (info.interlace == 0) {
        return @as(usize, info.height) * (1 + info.rowBytes(info.width));
    }
    var total: usize = 0;
    for (0..passes.len) |pass| {
        const size = passSize(info, pass);
        if (size.width == 0 or size.height == 0) continue;
        total += @as(usize, size.height) * (1 + info.rowBytes(size.width));
    }
    return total;
}

// --- undoing a filter -------------------------------------------------------

/// A row put back the way it was before it was written down. `row` is
/// the row's bytes without its filter byte, `above` the row before it -
/// zeroes for the first - and `pixel` how far a filter counts back.
pub fn unfilter(kind: u8, row: []u8, above: []const u8, pixel: u32) Error!void {
    switch (kind) {
        0 => {},
        // Each byte was written as the difference from the one a pixel
        // to its left.
        1 => for (pixel..row.len) |i| {
            row[i] = row[i] +% row[i - pixel];
        },
        2 => for (0..row.len) |i| {
            row[i] = row[i] +% above[i];
        },
        3 => for (0..row.len) |i| {
            const left: u32 = if (i >= pixel) row[i - pixel] else 0;
            row[i] = row[i] +% @as(u8, @truncate((left + above[i]) / 2));
        },
        4 => for (0..row.len) |i| {
            const left: i32 = if (i >= pixel) row[i - pixel] else 0;
            const up: i32 = above[i];
            const corner: i32 = if (i >= pixel) above[i - pixel] else 0;
            row[i] = row[i] +% @as(u8, @truncate(@as(u32, @bitCast(nearest(left, up, corner)))));
        },
        else => return Error.Corrupt,
    }
}

/// Of the byte to the left, the one above and the one diagonally back,
/// whichever is nearest their sum less the corner.
fn nearest(left: i32, up: i32, corner: i32) i32 {
    const guess = left + up - corner;
    const to_left = @abs(guess - left);
    const to_up = @abs(guess - up);
    const to_corner = @abs(guess - corner);
    if (to_left <= to_up and to_left <= to_corner) return left;
    if (to_up <= to_corner) return up;
    return corner;
}

// --- a row read as colour ---------------------------------------------------

/// The palette a file of colour kind 3 has, with what `tRNS` said about
/// it.
pub const Palette = struct {
    color: [256][4]u8 = @splat(.{ 0, 0, 0, 0xFF }),
    count: u32 = 0,
    /// The one colour that stands for nothing, for kinds 0 and 2: the
    /// file's own numbers, before they are narrowed to eight bits.
    transparent: ?[3]u16 = null,
};

/// One channel of a pixel, whatever depth the file holds it at, as a
/// number from 0 to 255.
fn channelAt(row: []const u8, index: usize, depth: u8) u8 {
    return switch (depth) {
        16 => row[index * 2],
        8 => row[index],
        // Fewer than eight bits: the value spread over the range, so
        // that all-ones comes back as 0xFF.
        4 => spread(@truncate((row[index / 2] >> @truncate(4 - 4 * (index & 1))) & 0x0F), 4),
        2 => spread(@truncate((row[index / 4] >> @truncate(6 - 2 * (index & 3))) & 0x03), 2),
        else => spread(@truncate((row[index / 8] >> @truncate(7 - (index & 7))) & 1), 1),
    };
}

fn spread(value: u8, bits: u3) u8 {
    return switch (bits) {
        1 => if (value != 0) 0xFF else 0,
        2 => value * 0x55,
        4 => value * 0x11,
        else => value,
    };
}

/// The raw number a channel holds, not narrowed: what `tRNS` is compared
/// against.
fn rawAt(row: []const u8, index: usize, depth: u8) u16 {
    return switch (depth) {
        16 => @as(u16, row[index * 2]) << 8 | row[index * 2 + 1],
        8 => row[index],
        4 => (row[index / 2] >> @truncate(4 - 4 * (index & 1))) & 0x0F,
        2 => (row[index / 4] >> @truncate(6 - 2 * (index & 3))) & 0x03,
        else => (row[index / 8] >> @truncate(7 - (index & 7))) & 1,
    };
}

/// `count` pixels of an unfiltered row read into `into` as red, green,
/// blue and coverage.
pub fn expand(info: Info, palette: *const Palette, row: []const u8, count: u32, into: []u8) void {
    const depth = info.depth;
    var x: u32 = 0;
    while (x < count) : (x += 1) {
        const out = into[x * 4 ..];
        switch (info.color) {
            0 => {
                const grey = channelAt(row, x, depth);
                out[0] = grey;
                out[1] = grey;
                out[2] = grey;
                out[3] = coverOf(palette, rawAt(row, x, depth), null, null);
            },
            2 => {
                const red = rawAt(row, x * 3, depth);
                const green = rawAt(row, x * 3 + 1, depth);
                const blue = rawAt(row, x * 3 + 2, depth);
                out[0] = channelAt(row, x * 3, depth);
                out[1] = channelAt(row, x * 3 + 1, depth);
                out[2] = channelAt(row, x * 3 + 2, depth);
                out[3] = coverOf(palette, red, green, blue);
            },
            3 => {
                const index = rawAt(row, x, depth);
                const color = palette.color[@min(index, 255)];
                out[0] = color[0];
                out[1] = color[1];
                out[2] = color[2];
                out[3] = color[3];
            },
            4 => {
                const grey = channelAt(row, x * 2, depth);
                out[0] = grey;
                out[1] = grey;
                out[2] = grey;
                out[3] = channelAt(row, x * 2 + 1, depth);
            },
            else => {
                out[0] = channelAt(row, x * 4, depth);
                out[1] = channelAt(row, x * 4 + 1, depth);
                out[2] = channelAt(row, x * 4 + 2, depth);
                out[3] = channelAt(row, x * 4 + 3, depth);
            },
        }
    }
}

/// Whether a pixel is the one colour `tRNS` named.
fn coverOf(palette: *const Palette, red: u16, green: ?u16, blue: ?u16) u8 {
    const said = palette.transparent orelse return 0xFF;
    if (said[0] != red) return 0xFF;
    if (green) |value| {
        if (said[1] != value or said[2] != blue.?) return 0xFF;
    }
    return 0;
}

/// `PLTE` and `tRNS` read into a palette.
pub fn readPalette(info: Info, palette: *Palette, plte: []const u8, trns: []const u8) Error!void {
    if (info.color == 3) {
        if (plte.len == 0 or plte.len % 3 != 0 or plte.len > 256 * 3) return Error.Corrupt;
        palette.count = @intCast(plte.len / 3);
        for (0..palette.count) |i| {
            palette.color[i] = .{ plte[i * 3], plte[i * 3 + 1], plte[i * 3 + 2], 0xFF };
        }
        for (trns, 0..) |cover, i| {
            if (i >= palette.count) break;
            palette.color[i][3] = cover;
        }
        return;
    }
    if (trns.len == 0) return;
    if (info.color == 0 and trns.len >= 2) {
        const grey = @as(u16, trns[0]) << 8 | trns[1];
        palette.transparent = .{ grey, grey, grey };
    } else if (info.color == 2 and trns.len >= 6) {
        palette.transparent = .{
            @as(u16, trns[0]) << 8 | trns[1],
            @as(u16, trns[2]) << 8 | trns[3],
            @as(u16, trns[4]) << 8 | trns[5],
        };
    }
}

// --- the chunk checksum -----------------------------------------------------

const crc_table = makeCrcTable();

fn makeCrcTable() [256]u32 {
    @setEvalBranchQuota(20000);
    var table: [256]u32 = undefined;
    for (0..256) |i| {
        var value: u32 = @intCast(i);
        for (0..8) |_| {
            value = if (value & 1 != 0) 0xEDB88320 ^ (value >> 1) else value >> 1;
        }
        table[i] = value;
    }
    return table;
}

/// The checksum a chunk ends with, over its four characters and its
/// bytes.
pub fn crc32(bytes: []const u8) u32 {
    var value: u32 = 0xFFFFFFFF;
    for (bytes) |byte| value = crc_table[(value ^ byte) & 0xFF] ^ (value >> 8);
    return ~value;
}
