// SPDX-License-Identifier: MIT
//! Host tests of the Movie's frame rate: a count turned into pictures a
//! second.

const std = @import("std");
const rate_file = @import("../rate.zig");

const testing = std.testing;

test "a second of 24 pictures and one given back is 24.0 a second, one dropped" {
    var rate = rate_file.FrameRate{ .ib = undefined, .gb = undefined };
    rate.restart(5_000_000);
    for (0..24) |_| rate.count(true);
    rate.count(false);
    try testing.expect(!rate.due(5_999_999));
    try testing.expect(rate.due(6_000_000));
    const taken = rate.take(6_000_000);
    try testing.expectEqual(@as(u32, 240), taken.tenths);
    try testing.expectEqual(@as(u32, 1), taken.dropped);
    // Counting began again.
    try testing.expectEqual(@as(u32, 0), rate.shown);
    try testing.expect(!rate.due(6_500_000));
}

test "a count over a longer while: 30 pictures in 1.25 seconds is 24.0" {
    var rate = rate_file.FrameRate{ .ib = undefined, .gb = undefined };
    rate.restart(0);
    for (0..30) |_| rate.count(true);
    try testing.expectEqual(@as(u32, 240), rate.take(1_250_000).tenths);
}
