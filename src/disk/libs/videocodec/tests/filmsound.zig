// SPDX-License-Identifier: MIT
//! filmsound's clock: the time heard, carried on between the steps of the
//! device's position by the machine's clock.

const std = @import("std");
const Clock = @import("../filmsound.zig").Clock;
const testing = std.testing;

test "the clock: carried on between steps, no further than a step, held rather than back, afresh when forgotten" {
    var clock: Clock = .{};
    // Said as it is until a step has been seen: nothing to carry on by.
    try testing.expectEqual(@as(i64, 1_000_000), clock.at(1_000_000, 50_000));
    try testing.expectEqual(@as(i64, 1_000_000), clock.at(1_000_000, 55_000));
    // A step of 512 frames at 48 kHz; from then on carried by the clock.
    try testing.expectEqual(@as(i64, 1_010_667), clock.at(1_010_667, 61_000));
    try testing.expectEqual(@as(i64, 1_014_667), clock.at(1_010_667, 65_000));
    // No further than a step while the position stands.
    try testing.expectEqual(@as(i64, 1_021_334), clock.at(1_010_667, 90_000));
    try testing.expectEqual(@as(i64, 1_021_334), clock.at(1_010_667, 400_000));
    // The next step: carried on from the step's end, where the clock was.
    try testing.expectEqual(@as(i64, 1_022_334), clock.at(1_021_334, 401_000));
    try testing.expectEqual(@as(i64, 1_027_334), clock.at(1_021_334, 406_000));

    // A shorter step moves the clock back into it: what was said is held.
    var held: Clock = .{};
    _ = held.at(0, 0);
    try testing.expectEqual(@as(i64, 10_000), held.at(10_000, 10_000));
    try testing.expectEqual(@as(i64, 19_000), held.at(10_000, 19_000));
    try testing.expectEqual(@as(i64, 19_000), held.at(12_000, 19_500));
    try testing.expectEqual(@as(i64, 19_000), held.at(12_000, 26_000));
    // Forgotten - a seek back: the next time is said as it is.
    held.forget();
    try testing.expectEqual(@as(i64, 5_000), held.at(5_000, 30_000));

    // A first step seen late is no longer than the longest carried on.
    var late: Clock = .{};
    _ = late.at(0, 0);
    _ = late.at(200_000, 200_000);
    try testing.expectEqual(@as(i64, 250_000), late.at(200_000, 900_000));
}

test "the clock settles where the steps fall: within a millisecond of the true time, read every 8 ms over steps of 10.667 ms" {
    var clock: Clock = .{};
    var worst: u64 = 0;
    var read: u64 = 0;
    while (read < 400) : (read += 1) {
        const now = 1_000 + read * 8_000;
        // The true time is the machine's; the position says it by steps.
        const position: i64 = @intCast(now / 10_667 * 10_667);
        const said = clock.at(position, now);
        if (read >= 100) worst = @max(worst, @abs(said - @as(i64, @intCast(now))));
    }
    try testing.expect(worst < 1_000);
}
