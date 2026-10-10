// SPDX-License-Identifier: MPL-2.0
//! What a JPEG file says before its picture: read from its bytes into a
//! `Header`, and checked against what the codec takes.
//!
//! A file is a run of segments, each named by a marker - 0xFF and a code:
//! the quantization tables (DQT), the code tables (DHT), the frame - the
//! picture's size and components (SOF0) - the restart interval (DRI), and
//! then the scan (SOS), after which the coded picture runs to the end
//! (EOI). Application data (APPn) and comments (COM) are skipped by their
//! length; a marker may be preceded by any number of 0xFF fill bytes.
//!
//! The codec reads the tables from its registers and the scan from its
//! header on, so what is kept here is what goes into the registers -
//! the quantization tables in natural order, the code tables as their
//! counts and symbols - and where the scan starts.
//!
//! **What the codec takes**: a baseline frame (SOF0, 8-bit samples), one
//! component (grey, sampled 1x1) or three (the first sampled 1x1, 2x1 or
//! 2x2, the other two 1x1), a single scan holding all of them, code
//! tables 0 and 1 of each kind, quantization tables 0 to 3 of 8-bit
//! entries, and a picture that in whole blocks of its sampling (`mcu_*`)
//! is at most 16383 pixels either way and whose pixel count is a whole
//! number of eights. Everything else is `Error.Unsupported`, which a
//! caller takes as "decode it some other way".

const types = @import("sdk").resources.jpeg;

pub const Error = error{
    /// It does not begin the way a JPEG does.
    NotJpeg,
    /// It does, and then says something the format does not allow, or
    /// ends before its scan.
    Corrupt,
    /// Something the format allows and the codec does not take.
    Unsupported,
};

/// The markers that matter, past the 0xFF that introduces each.
const M_SOF0: u8 = 0xC0;
const M_DHT: u8 = 0xC4;
const M_SOI: u8 = 0xD8;
const M_EOI: u8 = 0xD9;
const M_SOS: u8 = 0xDA;
const M_DQT: u8 = 0xDB;
const M_DRI: u8 = 0xDD;
const M_RST0: u8 = 0xD0;
const M_RST7: u8 = 0xD7;
const M_TEM: u8 = 0x01;

/// The order the sixty-four entries of a table are written in: out from
/// the corner, diagonal by diagonal. Entry `i` of the file is entry
/// `zigzag[i]` of the table in natural order.
const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

/// The most pixels the 2D-DMA's fields hold either way.
pub const side_max: u32 = 0x3FFF;

/// A code table: how many codes there are of each length, 1 to 16 bits,
/// and the symbol each stands for, in order.
pub const CodeTable = struct {
    counts: [16]u8 = @splat(0),
    symbols: [256]u8 = @splat(0),
};

/// One component of the frame: its number, its sampling across and down,
/// its quantization table.
pub const Component = struct {
    id: u8 = 0,
    across: u8 = 0,
    down: u8 = 0,
    table: u8 = 0,
};

pub const Header = struct {
    /// The picture's size, and the size the codec decodes it at: whole
    /// blocks of `mcu_width` x `mcu_height`.
    width: u32 = 0,
    height: u32 = 0,
    padded_width: u32 = 0,
    padded_height: u32 = 0,
    mcu_width: u32 = 0,
    mcu_height: u32 = 0,
    count: u32 = 0,
    component: [3]Component = @splat(.{}),
    /// JPEGSAMP_*.
    sampling: u32 = 0,
    /// The quantization tables in natural order, and which of them the
    /// file gave (bit n: table n).
    quantization: [4][64]u16 = @splat(@splat(0)),
    quantization_given: u4 = 0,
    /// The code tables, [DC, AC][0, 1], and which the file gave (bit
    /// class * 2 + number).
    code: [2][2]CodeTable = @splat(@splat(.{})),
    code_given: u4 = 0,
    /// Blocks between restart markers, 0 for none.
    restart: u32 = 0,
    /// Where the scan's marker is: the codec reads from there to the end.
    scan: u32 = 0,

    /// What a decoded picture is: JPEGFMT_*, and its bytes per pixel.
    pub fn format(h: *const Header) u32 {
        return if (h.count == 1) types.JPEGFMT_GREY8 else types.JPEGFMT_BGR24;
    }

    pub fn bytesPerPixel(h: *const Header) u32 {
        return if (h.count == 1) 1 else 3;
    }

    /// From one row of the decoded picture to the next, and all of it.
    pub fn pitch(h: *const Header) u32 {
        return h.padded_width * h.bytesPerPixel();
    }

    pub fn bytes(h: *const Header) u32 {
        return h.pitch() * h.padded_height;
    }
};

/// The bytes of a file, read from the front.
const Reader = struct {
    file: []const u8,
    at: usize = 0,

    fn byte(r: *Reader) Error!u8 {
        if (r.at >= r.file.len) return Error.Corrupt;
        r.at += 1;
        return r.file[r.at - 1];
    }

    fn word(r: *Reader) Error!u16 {
        const high = try r.byte();
        return @as(u16, high) << 8 | try r.byte();
    }

    /// A segment's body: its length word read, the rest of it handed out
    /// as a reader of its own and skipped here.
    fn segment(r: *Reader) Error!Reader {
        const length = try r.word();
        if (length < 2 or r.file.len - r.at < length - 2) return Error.Corrupt;
        const body: Reader = .{ .file = r.file[r.at .. r.at + length - 2] };
        r.at += length - 2;
        return body;
    }
};

/// The headers of `file`, up to its scan, into `h` - a header is large
/// enough to be kept off a task's stack.
pub fn read(file: []const u8, h: *Header) Error!void {
    if (file.len < 4 or file[0] != 0xFF or file[1] != M_SOI) return Error.NotJpeg;
    var r: Reader = .{ .file = file, .at = 2 };
    h.* = .{};
    var framed = false;
    while (true) {
        if (try r.byte() != 0xFF) return Error.Corrupt;
        var marker = try r.byte();
        while (marker == 0xFF) marker = try r.byte();
        switch (marker) {
            M_SOF0 => {
                if (framed) return Error.Corrupt;
                var body = try r.segment();
                try frame(&body, h);
                framed = true;
            },
            // Every other frame: extended, progressive, lossless,
            // arithmetic coding.
            0xC1...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => return Error.Unsupported,
            M_DHT => {
                var body = try r.segment();
                try codeTables(&body, h);
            },
            M_DQT => {
                var body = try r.segment();
                try quantizationTables(&body, h);
            },
            M_DRI => {
                var body = try r.segment();
                h.restart = try body.word();
            },
            M_SOS => {
                if (!framed) return Error.Corrupt;
                h.scan = @intCast(r.at - 2);
                var body = try r.segment();
                try scan(&body, h);
                return;
            },
            M_SOI, M_EOI => return Error.Corrupt,
            M_TEM, M_RST0...M_RST7 => {},
            0x00 => return Error.Corrupt,
            else => _ = try r.segment(),
        }
    }
}

/// SOF0: the precision, the size, and each component's number, sampling
/// and table.
fn frame(body: *Reader, h: *Header) Error!void {
    if (try body.byte() != 8) return Error.Unsupported;
    h.height = try body.word();
    h.width = try body.word();
    h.count = try body.byte();
    if (h.width == 0 or h.height == 0) return Error.Unsupported;
    if (h.count != 1 and h.count != 3) return Error.Unsupported;
    for (h.component[0..h.count]) |*c| {
        c.id = try body.byte();
        const sampling = try body.byte();
        c.across = sampling >> 4;
        c.down = sampling & 0xF;
        c.table = try body.byte();
        if (c.table > 3) return Error.Corrupt;
    }
    const first = h.component[0];
    if (h.count == 1) {
        if (first.across != 1 or first.down != 1) return Error.Unsupported;
        h.sampling = types.JPEGSAMP_GREY;
    } else {
        for (h.component[1..3]) |c| {
            if (c.across != 1 or c.down != 1) return Error.Unsupported;
        }
        h.sampling = switch (@as(u16, first.across) << 4 | first.down) {
            0x11 => types.JPEGSAMP_444,
            0x21 => types.JPEGSAMP_422,
            0x22 => types.JPEGSAMP_420,
            else => return Error.Unsupported,
        };
    }
    h.mcu_width = @as(u32, first.across) * 8;
    h.mcu_height = @as(u32, first.down) * 8;
    h.padded_width = (h.width + h.mcu_width - 1) / h.mcu_width * h.mcu_width;
    h.padded_height = (h.height + h.mcu_height - 1) / h.mcu_height * h.mcu_height;
    if (h.padded_width > side_max or h.padded_height > side_max) return Error.Unsupported;
    if (h.width * h.height % 8 != 0) return Error.Unsupported;
}

/// DHT: one or more code tables, each its class and number, sixteen
/// counts and the symbols.
fn codeTables(body: *Reader, h: *Header) Error!void {
    while (body.at < body.file.len) {
        const which = try body.byte();
        const class = which >> 4;
        const number = which & 0xF;
        if (class > 1) return Error.Corrupt;
        if (number > 1) return Error.Unsupported;
        const table = &h.code[class][number];
        var total: u32 = 0;
        for (&table.counts) |*count| {
            count.* = try body.byte();
            total += count.*;
        }
        if (total > 256 or (class == 0 and total > 16)) return Error.Corrupt;
        table.symbols = @splat(0);
        for (table.symbols[0..total]) |*symbol| symbol.* = try body.byte();
        h.code_given |= @as(u4, 1) << @intCast(class * 2 + number);
    }
}

/// DQT: one or more quantization tables, each its precision and number
/// and sixty-four entries in zigzag order.
fn quantizationTables(body: *Reader, h: *Header) Error!void {
    while (body.at < body.file.len) {
        const which = try body.byte();
        const precision = which >> 4;
        const number = which & 0xF;
        if (precision > 1 or number > 3) return Error.Corrupt;
        if (precision != 0) return Error.Unsupported;
        for (zigzag) |natural| h.quantization[number][natural] = try body.byte();
        h.quantization_given |= @as(u4, 1) << @intCast(number);
    }
}

/// SOS: a single scan of every component, its tables among those the
/// file gave and the codec holds, the whole of each block in one pass.
fn scan(body: *Reader, h: *Header) Error!void {
    if (try body.byte() != h.count) return Error.Unsupported;
    for (h.component[0..h.count]) |c| {
        if (try body.byte() != c.id) return Error.Unsupported;
        const tables = try body.byte();
        const dc = tables >> 4;
        const ac = tables & 0xF;
        if (dc > 1 or ac > 1) return Error.Unsupported;
        const dc_bit = @as(u4, 1) << @intCast(dc);
        const ac_bit = @as(u4, 1) << @intCast(2 + ac);
        if (h.code_given & dc_bit == 0 or h.code_given & ac_bit == 0) return Error.Unsupported;
        if (h.quantization_given & (@as(u4, 1) << @intCast(c.table)) == 0) return Error.Corrupt;
    }
    if (try body.byte() != 0 or try body.byte() != 63 or try body.byte() != 0) return Error.Unsupported;
}

/// What ExamineJPEG answers for a header: its size, its colour, and what
/// DecodeJPEG will make of it.
pub fn infoOf(h: *const Header) types.JPEGInfo {
    return .{
        .width = h.width,
        .height = h.height,
        .components = h.count,
        .sampling = h.sampling,
        .format = h.format(),
        .pitch = h.pitch(),
        .bytes = h.bytes(),
    };
}

/// A parse error as ExamineJPEG and DecodeJPEG answer it.
pub fn errorOf(failure: Error) u32 {
    return switch (failure) {
        Error.NotJpeg => types.JPEGERR_NOT_JPEG,
        Error.Corrupt => types.JPEGERR_CORRUPT,
        Error.Unsupported => types.JPEGERR_UNSUPPORTED,
    };
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "a colour picture's headers: size, sampling, tables, where the scan is" {
    var h: Header = .{};
    try read(@embedFile("../../../../disk/tests/datatypes/Garden.jpg"), &h);
    try testing.expectEqual(@as(u32, 120), h.width);
    try testing.expectEqual(@as(u32, 80), h.height);
    try testing.expectEqual(@as(u32, 3), h.count);
    try testing.expectEqual(types.JPEGSAMP_420, h.sampling);
    try testing.expectEqual(@as(u32, 16), h.mcu_width);
    try testing.expectEqual(@as(u32, 128), h.padded_width);
    try testing.expectEqual(@as(u32, 80), h.padded_height);
    try testing.expectEqual(@as(u4, 0b1111), h.code_given);
    try testing.expectEqual(@as(u4, 0b0011), h.quantization_given);
    try testing.expectEqual(@as(u32, 128 * 3), h.pitch());
    const file = @embedFile("../../../../disk/tests/datatypes/Garden.jpg");
    try testing.expectEqual(@as(u8, 0xFF), file[h.scan]);
    try testing.expectEqual(M_SOS, file[h.scan + 1]);
}

test "a grey picture: one component, one byte a pixel" {
    var h: Header = .{};
    try read(@embedFile("../../../../disk/tests/datatypes/Grey.jpg"), &h);
    try testing.expectEqual(@as(u32, 1), h.count);
    try testing.expectEqual(types.JPEGSAMP_GREY, h.sampling);
    try testing.expectEqual(types.JPEGFMT_GREY8, h.format());
    try testing.expectEqual(@as(u32, 120), h.pitch());
}

test "what is not a JPEG, what is cut short, what the codec does not take" {
    var h: Header = .{};
    try testing.expectError(Error.NotJpeg, read("GIF89a", &h));
    const file = @embedFile("../../../../disk/tests/datatypes/Garden.jpg");
    try read(file, &h);
    try testing.expectError(Error.Corrupt, read(file[0..h.scan], &h));
    var progressive: [file.len]u8 = file.*;
    var at: usize = 2;
    while (!(progressive[at] == 0xFF and progressive[at + 1] == M_SOF0)) at += 1;
    progressive[at + 1] = 0xC2;
    try testing.expectError(Error.Unsupported, read(&progressive, &h));
}
