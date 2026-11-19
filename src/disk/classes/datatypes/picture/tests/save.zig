// SPDX-License-Identifier: MIT
//! Host tests of picture.datatype's ILBM writer against ilbm.datatype's
//! reader: a row of pens made into planes and gathered back is the row
//! it was, channel for channel.

const std = @import("std");
const save = @import("../save.zig");
const planes = @import("../../ilbm/planes.zig");

const testing = std.testing;

test "a deep row written as planes reads back as the same colours" {
    const width = 21;
    var pens: [width]u32 = undefined;
    for (&pens, 0..) |*pen, x| {
        const step: u32 = @intCast(x);
        pen.* = (0xFF - step) << 24 | (step * 12) << 16 | (0x80 + step) << 8 | (0xF0 - step * 3);
    }
    const stride = comptime planes.planeStride(width);
    inline for (.{ 24, 32 }) |depth| {
        var body: [32 * stride]u8 = undefined;
        save.rowPlanes(&pens, width, depth, stride, &body);
        var numbers: [width]u32 = undefined;
        planes.gather(&body, stride, depth, width, &numbers);
        var rgba: [width * 4]u8 = undefined;
        planes.toRGBA(&numbers, width, depth, 0, &.{}, null, &rgba);
        for (pens, 0..) |pen, x| {
            try testing.expectEqual(@as(u8, @truncate(pen >> 16)), rgba[x * 4]);
            try testing.expectEqual(@as(u8, @truncate(pen >> 8)), rgba[x * 4 + 1]);
            try testing.expectEqual(@as(u8, @truncate(pen)), rgba[x * 4 + 2]);
            try testing.expectEqual(if (depth == 32) @as(u8, @truncate(pen >> 24)) else 0xFF, rgba[x * 4 + 3]);
        }
    }
}
