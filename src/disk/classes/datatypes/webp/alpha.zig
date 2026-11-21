// SPDX-License-Identifier: MIT
//! A lossy WebP picture's coverage (`ALPH`, RFC 9649 section 2.7.1.2): a
//! byte a pixel, as they are or as a lossless stream's green, each
//! perhaps the difference from what its neighbours predict.
//!
//! The chunk's first byte says how: the lowest two bits whether the
//! bytes are kept as they are (0) or in a lossless stream without its
//! header (1); the next two the prediction undone - none, from the left,
//! from above, or the gradient left plus above less above-left, held to
//! a byte. The first pixel is predicted as nothing, the rest of the first
//! row from the left and the first of each other row from above, by
//! every prediction. A reduction of the levels before the picture was
//! coded (the next two bits) needs nothing of a decoder.

const lossless = @import("lossless.zig");

pub const Env = lossless.Env;
pub const Error = lossless.Error;

/// The coverage of a `width` by `height` picture from its chunk, into
/// `into`, a byte a pixel.
pub fn decode(env: Env, chunk: []const u8, width: u32, height: u32, into: []u8) Error!void {
    if (chunk.len < 1) return Error.Corrupt;
    const header = chunk[0];
    const compression = header & 3;
    const filter = (header >> 2) & 3;
    if (header >> 6 != 0 or compression > 1) return Error.Corrupt;
    const total = @as(usize, width) * height;
    if (into.len < total) return Error.NoMemory;
    const data = chunk[1..];
    if (compression == 0) {
        if (data.len < total) return Error.Corrupt;
        @memcpy(into[0..total], data[0..total]);
    } else {
        const pixels = env.slice(u32, total) orelse return Error.NoMemory;
        defer env.freeSlice(u32, pixels);
        try lossless.decodeBody(env, data, width, height, pixels);
        for (into[0..total], pixels) |*coverage, pixel| coverage.* = @truncate(pixel >> 8);
    }
    unfilter(into[0..total], width, height, filter);
}

/// The prediction undone, row after row.
fn unfilter(bytes: []u8, width: u32, height: u32, filter: u8) void {
    if (filter == 0) return;
    for (0..height) |y| {
        const row = bytes[y * width ..][0..width];
        if (y == 0) {
            // From the left, the first from nothing.
            var left: u8 = 0;
            for (row) |*value| {
                value.* +%= left;
                left = value.*;
            }
            continue;
        }
        const above = bytes[(y - 1) * width ..][0..width];
        switch (filter) {
            1 => {
                var left = above[0];
                for (row) |*value| {
                    value.* +%= left;
                    left = value.*;
                }
            },
            2 => for (row, above) |*value, top| {
                value.* +%= top;
            },
            else => {
                var left = above[0];
                var top_left = above[0];
                for (row, above) |*value, top| {
                    const guess: i32 = @as(i32, left) + top - top_left;
                    value.* +%= @intCast(@max(0, @min(255, guess)));
                    left = value.*;
                    top_left = top;
                }
            },
        }
    }
}

const std = @import("std");
const testing = std.testing;

test "coverage kept as it is" {
    const chunk = [_]u8{ 0, 1, 2, 3, 4, 5, 6 };
    var into: [6]u8 = undefined;
    try decode(undefined, &chunk, 3, 2, &into);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, &into);
}

test "each prediction undone" {
    // From the left: the first row and each row's first from above.
    var left = [_]u8{ 10, 1, 1, 5, 1, 1 };
    unfilter(&left, 3, 2, 1);
    try testing.expectEqualSlices(u8, &.{ 10, 11, 12, 15, 16, 17 }, &left);
    var above = [_]u8{ 10, 1, 1, 5, 1, 1 };
    unfilter(&above, 3, 2, 2);
    try testing.expectEqualSlices(u8, &.{ 10, 11, 12, 15, 12, 13 }, &above);
    // The gradient: left + top - top-left, held to a byte.
    var gradient = [_]u8{ 10, 20, 30, 0, 0, 0 };
    unfilter(&gradient, 3, 2, 3);
    try testing.expectEqualSlices(u8, &.{ 10, 30, 60, 10, 30, 60 }, &gradient);
}
