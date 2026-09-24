// SPDX-License-Identifier: MPL-2.0
//! Date2Amiga: a ClockData as seconds since 1 January 1978. The date is
//! not checked; `CheckDate` does that.

const std = @import("std");
const sdk = @import("sdk");
const _date = @import("_date.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const ClockData = sdk.utility.ClockData;
const Amiga2Date = @import("amiga2date.zig").Amiga2Date;
const CheckDate = @import("checkdate.zig").CheckDate;

/// Turns a date into seconds since 1 January 1978.
///
/// SYNOPSIS:
/// ```zig
/// fn Date2Amiga(_: *UtilityBase, clock_data: *const ClockData) u32
/// ```
///
/// SINCE: 1.0. LVO -84.
///
/// INPUTS:
/// - `clock_data` - the date. Its weekday is ignored, and nothing in it is
///   checked.
///
/// RESULT:
/// The seconds, as the low 32 bits of the count. A date before 1978 or
/// after 7 February 2114, 06:28:15 wraps.
///
/// BEHAVIOR:
/// Plain arithmetic on the fields, so a field out of its range carries into
/// the next: 31 April is 1 May, and hour 24 is the next day's midnight.
/// `CheckDate` is the call that refuses such a date.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads only its inputs and allocates nothing.
/// - Forbid: not needed, and not taken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Amiga2Date`, `CheckDate`
///
/// EXAMPLES:
/// ```zig
/// const seconds = ub.Date2Amiga(&cd);
/// ```
pub fn Date2Amiga(_: *UtilityBase, clock_data: *const ClockData) u32 {
    return @truncate(@as(u64, @bitCast(secondsOf(clock_data))));
}

/// A date as seconds since 1 January 1978, before it is cut to 32 bits.
///
/// INPUTS:
/// - `date` - the date; its weekday is ignored.
fn secondsOf(date: *const ClockData) i64 {
    const days = _date.daysFromCivil(date.year, date.month, date.mday) - _date.amiga_epoch;
    return days * _date.secs_per_day + @as(i64, date.hour) * 3600 + @as(i64, date.min) * 60 + date.sec;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

test "Date2Amiga turns Amiga2Date back" {
    const ub = try library.setUp();
    defer kexec.deinit();
    var cd: ClockData = .{};
    for ([_]u32{ 0, 59, 86_399, 86_400, 694_224_000, 951_782_400, 1_234_567_890, 0xFFFF_FFFF }) |secs| {
        Amiga2Date(ub, secs, &cd);
        try testing.expectEqual(secs, Date2Amiga(ub, &cd));
        if (secs != 0) try testing.expectEqual(secs, CheckDate(ub, &cd));
    }
    try library.tearDown(ub);
}
