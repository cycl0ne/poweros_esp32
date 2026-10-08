// SPDX-License-Identifier: MIT
//! Host tests of the PNG decoder png.datatype and icon.library read
//! with (sdk/libs/datatypes/png/): the DEFLATE stream - stored, fixed and
//! own codes, a truncated stream, one too long for its room - then the
//! chunks' checksum, the header, the filters, the bits of a pixel and
//! the passes of an interlaced file.

const std = @import("std");
const sdk = @import("sdk");
const inflate = sdk.datatypes.png.inflate;
const decode = sdk.datatypes.png.decode;

const testing = std.testing;

// --- the stream -------------------------------------------------------------

test "a stored block comes back as it is" {
    // 0x01: last block, stored; then the length and its complement.
    const stream = [_]u8{ 0x01, 0x05, 0x00, 0xFA, 0xFF, 'h', 'e', 'l', 'l', 'o' };
    var work = inflate.Work{};
    var into: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try inflate.inflate(&work, &stream, &into));
    try testing.expectEqualStrings("hello", into[0..5]);
}

test "a run is coded as a repeat of itself" {
    // Sixty 'a's, which the coder writes as one byte and a repeat that
    // reads out of what it is itself writing.
    const stream = [_]u8{
        0x78, 0x9c, 0x4b, 0x4c, 0x24, 0x1f, 0x00, 0x00, 0xb5, 0xc0, 0x16, 0xbd,
    };
    var work = inflate.Work{};
    var into: [64]u8 = undefined;
    const written = try inflate.uncompress(&work, &stream, &into);
    try testing.expectEqual(@as(usize, 60), written);
    for (into[0..written]) |byte| try testing.expectEqual(@as(u8, 'a'), byte);
}

test "a block with its own codes" {
    const stream = [_]u8{
        0x78, 0xda, 0x2d, 0x8d, 0xdb, 0x11, 0xc3, 0x20, 0x0c, 0x04, 0x5b, 0xb9,
        0xd4, 0xe1, 0x6a, 0x20, 0x16, 0xa0, 0x04, 0x23, 0x9b, 0xa7, 0xa1, 0xfa,
        0x68, 0x3c, 0xf9, 0xde, 0xbd, 0xbd, 0x1a, 0x08, 0x57, 0xe3, 0xf7, 0x17,
        0x36, 0xcb, 0x48, 0x70, 0x72, 0xe3, 0xd3, 0x8e, 0xb3, 0x40, 0x3a, 0x65,
        0x54, 0xc5, 0xd1, 0xac, 0x89, 0x5d, 0xfc, 0x86, 0xd3, 0xa8, 0x77, 0x4c,
        0x58, 0x95, 0x06, 0xd7, 0x00, 0xc7, 0x9d, 0x14, 0x2d, 0x4a, 0x88, 0x7c,
        0x35, 0xc9, 0xba, 0xf5, 0x65, 0x43, 0x90, 0x81, 0x4e, 0x37, 0x27, 0x1f,
        0xe7, 0x3f, 0xbf, 0x1b, 0x57, 0xb1, 0xc8, 0x66, 0x53, 0x9e, 0x83, 0xd7,
        0x0f, 0xbe, 0x65, 0x2c, 0xbd,
    };
    var work = inflate.Work{};
    var into: [256]u8 = undefined;
    const written = try inflate.uncompress(&work, &stream, &into);
    try testing.expectEqualStrings(
        "the quick brown fox jumps over the lazy dog; pack my box with five " ++
            "dozen liquor jugs; how vexingly quick daft zebras jump!",
        into[0..written],
    );
}

test "a truncated stream says so" {
    const stream = [_]u8{ 0x01, 0x05, 0x00, 0xFA, 0xFF, 'h', 'e' };
    var work = inflate.Work{};
    var into: [16]u8 = undefined;
    try testing.expectError(inflate.Error.Truncated, inflate.inflate(&work, &stream, &into));
}

test "more than there is room for says so" {
    const stream = [_]u8{ 0x01, 0x05, 0x00, 0xFA, 0xFF, 'h', 'e', 'l', 'l', 'o' };
    var work = inflate.Work{};
    var into: [3]u8 = undefined;
    try testing.expectError(inflate.Error.Overrun, inflate.inflate(&work, &stream, &into));
}

// --- the file ---------------------------------------------------------------

test "the checksum is the one the format defines" {
    try testing.expectEqual(@as(u32, 0xCBF43926), decode.crc32("123456789"));
}

test "a header read, and one this decoder will not take" {
    // An 8x8 grey PNG, made by hand: signature, IHDR, and the checksum
    // that goes with it.
    var file: [8 + 12 + 13]u8 = undefined;
    @memcpy(file[0..8], &decode.signature);
    file[8..12].* = .{ 0, 0, 0, 13 };
    @memcpy(file[12..16], "IHDR");
    file[16..20].* = .{ 0, 0, 0, 8 };
    file[20..24].* = .{ 0, 0, 0, 8 };
    file[24] = 8; // depth
    file[25] = 0; // grey
    file[26] = 0;
    file[27] = 0;
    file[28] = 0; // not interlaced
    const sum = decode.crc32(file[12..29]);
    file[29..33].* = .{ @truncate(sum >> 24), @truncate(sum >> 16), @truncate(sum >> 8), @truncate(sum) };
    const info = try decode.readInfo(&file);
    try testing.expectEqual(@as(u32, 8), info.width);
    try testing.expectEqual(@as(u32, 1), info.channels());
    try testing.expectEqual(@as(usize, 8 * 9), decode.rawSize(info));

    var wrong = file;
    wrong[0] = 'P';
    try testing.expectError(decode.Error.NotPng, decode.readInfo(&wrong));
}

test "a filter undone against the row above" {
    // Each byte the difference from the one above it.
    var row = [_]u8{ 1, 1, 1, 1 };
    const above = [_]u8{ 10, 20, 30, 40 };
    try decode.unfilter(2, &row, &above, 1);
    try testing.expectEqualSlices(u8, &.{ 11, 21, 31, 41 }, &row);

    // Each byte the difference from the one a pixel to its left.
    var sub = [_]u8{ 5, 1, 1, 1 };
    try decode.unfilter(1, &sub, &above, 1);
    try testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8 }, &sub);
}

test "a row of four-bit grey spreads over the whole range" {
    const info = decode.Info{ .width = 4, .depth = 4, .color = 0 };
    const palette = decode.Palette{};
    const row = [_]u8{ 0x0F, 0xF0 };
    var into: [16]u8 = undefined;
    decode.expand(info, &palette, &row, 4, &into);
    try testing.expectEqual(@as(u8, 0), into[0]);
    try testing.expectEqual(@as(u8, 0xFF), into[4]);
    try testing.expectEqual(@as(u8, 0xFF), into[8]);
    try testing.expectEqual(@as(u8, 0), into[12]);
    try testing.expectEqual(@as(u8, 0xFF), into[3]);
}

test "the passes of an interlaced file cover every pixel once" {
    const info = decode.Info{ .width = 9, .height = 9, .depth = 8, .color = 0, .interlace = 1 };
    var total: u32 = 0;
    for (0..decode.passes.len) |pass| {
        const size = decode.passSize(info, pass);
        total += size.width * size.height;
    }
    try testing.expectEqual(@as(u32, 81), total);
}
