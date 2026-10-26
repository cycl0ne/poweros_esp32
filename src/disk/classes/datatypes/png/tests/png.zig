// SPDX-License-Identifier: MIT
//! Host tests of the PNG decoder png.datatype and icon.library read
//! with (sdk/libs/datatypes/png/): the chunks' checksum, the header, the
//! filters, the bits of a pixel and the passes of an interlaced file.
//! The stream is compression.library's, tested with it; icon.library's
//! tests read whole files.

const std = @import("std");
const sdk = @import("sdk");
const decode = sdk.datatypes.png.decode;

const testing = std.testing;

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
