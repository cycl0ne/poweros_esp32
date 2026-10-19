// SPDX-License-Identifier: MIT
//! Host tests of MemMap's figures: amounts in the unit that suits them,
//! and the regions' pieces of the one band of a machine whose RAM is one
//! kind. The window is not here.

const std = @import("std");
const figures = @import("../figures.zig");

const testing = std.testing;

fn expectAmount(expected: []const u8, bytes: usize) !void {
    var text: [24]u8 = undefined;
    const length = figures.amount(&text, bytes);
    try testing.expectEqualStrings(expected, text[0..length]);
    try testing.expectEqual(@as(u8, 0), text[length]);
}

test "MemMap: an amount in bytes, KB, MB or GB, rounded down" {
    try expectAmount("0 bytes", 0);
    try expectAmount("1 byte", 1);
    try expectAmount("238 bytes", 238);
    try expectAmount("1 KB", 1024);
    try expectAmount("1023 KB", 1024 * 1024 - 1);
    try expectAmount("1.0 MB", 1024 * 1024);
    try expectAmount("32.6 MB", 34_280_976);
    try expectAmount("1023.9 MB", 1024 * 1024 * 1024 - 1);
    try expectAmount("1.00 GB", 1024 * 1024 * 1024);
    try expectAmount("2.00 GB", 2_147_483_552 + 96);
    try expectAmount("1.05 GB", 1024 * 1024 * 1024 + 60 * 1024 * 1024);
    try expectAmount("7.94 GB", 8_530_667_360);
}

test "MemMap: the regions' pieces of one band follow one another, each in proportion" {
    // Six regions as an 8 GiB machine has them, in the order of their
    // addresses: a pixel is the same number of bytes in each.
    const sizes = [_]usize{ 1659 * 1024, 523_275 * 1024, 1_556_479 * 1024, 2_097_151 * 1024, 2_097_151 * 1024, 2_097_151 * 1024 };
    var total: usize = 0;
    for (sizes) |size| total += size;
    const pixels: usize = 548 * 190;
    var before: usize = 0;
    var next: usize = 0;
    for (sizes) |size| {
        const piece = figures.share(before, size, total, pixels);
        try testing.expectEqual(next, piece.first);
        const exact = @as(f64, @floatFromInt(size)) * @as(f64, @floatFromInt(pixels)) / @as(f64, @floatFromInt(total));
        try testing.expect(@abs(@as(f64, @floatFromInt(piece.pixels)) - exact) <= 1.0);
        before += size;
        next = piece.first + piece.pixels;
    }
    try testing.expectEqual(pixels, next);
    // One region is the whole band; nothing at all is an empty one.
    try testing.expectEqual(figures.Piece{ .first = 0, .pixels = pixels }, figures.share(0, 4096, 4096, pixels));
    try testing.expectEqual(figures.Piece{ .first = 0, .pixels = 0 }, figures.share(0, 0, 0, pixels));
}
