// SPDX-License-Identifier: MPL-2.0
//! struct timeval and struct EClockVal, and timer.device's AddTime,
//! SubTime and CmpTime on them. No hardware: the host tests run these.

const std = @import("std");

/// struct timeval and struct EClockVal: the SDK's (sdk/devices/timer.zig).
pub const TimeVal = @import("sdk").devices.timer.TimeVal;
pub const EClockVal = @import("sdk").devices.timer.EClockVal;

/// dest += src, the microseconds carried into the seconds.
pub fn addTime(dest: *TimeVal, src: *const TimeVal) void {
    const micro = @as(u64, dest.micro) + src.micro;
    dest.* = .{
        .secs = dest.secs +% src.secs +% @as(u32, @truncate(micro / 1_000_000)),
        .micro = @intCast(micro % 1_000_000),
    };
}

/// dest -= src, borrowing a second when needed.
pub fn subTime(dest: *TimeVal, src: *const TimeVal) void {
    var secs = dest.secs -% src.secs;
    var micro = dest.micro;
    if (micro < src.micro) {
        micro += 1_000_000;
        secs -%= 1;
    }
    dest.* = .{ .secs = secs, .micro = micro -% src.micro };
}

/// 0 if they are equal, -1 if dest is later than src, +1 if it is earlier.
pub fn cmpTime(dest: *const TimeVal, src: *const TimeVal) i32 {
    const a = dest.toMicros();
    const b = src.toMicros();
    return if (a == b) 0 else if (a > b) -1 else 1;
}

const testing = std.testing;

test "AddTime carries, SubTime borrows" {
    var t: TimeVal = .{ .secs = 1, .micro = 700_000 };
    addTime(&t, &.{ .secs = 2, .micro = 500_000 });
    try testing.expectEqual(TimeVal{ .secs = 4, .micro = 200_000 }, t);
    subTime(&t, &.{ .secs = 0, .micro = 300_000 });
    try testing.expectEqual(TimeVal{ .secs = 3, .micro = 900_000 }, t);
    subTime(&t, &.{ .secs = 3, .micro = 900_000 });
    try testing.expectEqual(TimeVal{}, t);
}

test "CmpTime: 0 when equal, -1 when dest is later, +1 when earlier" {
    const a: TimeVal = .{ .secs = 5, .micro = 1 };
    const b: TimeVal = .{ .secs = 5, .micro = 2 };
    try testing.expectEqual(@as(i32, 0), cmpTime(&a, &a));
    try testing.expectEqual(@as(i32, 1), cmpTime(&a, &b));
    try testing.expectEqual(@as(i32, -1), cmpTime(&b, &a));
    try testing.expectEqual(@as(i32, -1), cmpTime(&.{ .secs = 6 }, &b));
}

test "microseconds and E-clock ticks" {
    try testing.expectEqual(TimeVal{ .secs = 3, .micro = 25 }, TimeVal.fromMicros(3_000_025));
    try testing.expectEqual(@as(u64, 3_000_025), (TimeVal{ .secs = 3, .micro = 25 }).toMicros());
    const ev = EClockVal.fromTicks(0x1_2345_6789);
    try testing.expectEqual(@as(u32, 1), ev.hi);
    try testing.expectEqual(@as(u32, 0x2345_6789), ev.lo);
    try testing.expectEqual(@as(u64, 0x1_2345_6789), ev.toTicks());
}
