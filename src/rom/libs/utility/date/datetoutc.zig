// SPDX-License-Identifier: MPL-2.0
//! DateToUtc: a DateStamp of the system clock as a moment in UTC.

const std = @import("std");
const sdk = @import("sdk");

const UtilityBase = @import("../utility.zig").UtilityBase;
const DateStamp = sdk.dos.DateStamp;
const _date = @import("_date.zig");

/// A DateStamp, kept in the zone the system clock keeps, as seconds since
/// 1970 in UTC.
///
/// SYNOPSIS:
/// ```zig
/// fn DateToUtc(ub: *UtilityBase, date: *const dos.DateStamp, nanoseconds: ?*u32) i64
/// ```
///
/// SINCE: 1.3. LVO -268.
///
/// INPUTS:
/// - `date` - the stamp: what `DateStamp` answers, or a file's date from
///   `Examine`. Its days count from 1 January 1978, its minutes from
///   midnight, its ticks (50 a second) from the start of the minute.
/// - `nanoseconds` - where the fraction of the second goes, in
///   nanoseconds (a tick is 20 000 000); null when it is not wanted.
///
/// RESULT:
/// The moment in seconds since 1 January 1970, UTC.
///
/// BEHAVIOR:
/// The stamp is read as local time in the system's zone (see
/// `ZoneOffset`). The offset is the one at the moment in UTC, which is
/// what is being found: the offset at the local time read as if it were
/// UTC gives a moment near enough to look it up at, but within the hour
/// summer time starts or ends. A local time in the hour the clocks skip
/// is answered as if the clocks had not changed yet; one in the hour they
/// go through twice, as the second time.
///
/// The zone is read once for the call, so both offsets are the same rule.
/// While nobody wrote the zone, the stamp is UTC already.
///
/// CONTEXT:
/// - Waits: yes, for battmem.resource's semaphore while another task
///   holds it.
/// - Interrupts: no.
/// - Locks: none needed; battmem.resource takes its own for the read.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. `date` and `nanoseconds` are the caller's.
///
/// NOTES:
/// It sends no packet and reads no file, so a file system handler may ask
/// it for a date on the volume that holds the zone file.
///
/// `UtcToDate` is the inverse, but for the fraction of the second, which
/// a count of seconds does not hold.
///
/// BUGS:
/// A stamp whose fields are out of their ranges carries into the next
/// field rather than being refused: 25 hours' worth of minutes is a day
/// and an hour.
///
/// SEE ALSO:
/// `UtcToDate`, `ZoneOffset`, `DateSplit`
///
/// EXAMPLES:
/// ```zig
/// var now: dos.DateStamp = .{};
/// _ = dl.DateStamp(&now);
/// const seconds = ub.DateToUtc(&now, null); // what a server or a certificate counts in
/// ```
pub fn DateToUtc(ub: *UtilityBase, date: *const DateStamp, nanoseconds: ?*u32) i64 {
    if (nanoseconds) |into| {
        const ticks: u32 = @intCast(@mod(date.tick, _date.ticks_per_second));
        into.* = ticks * (1_000_000_000 / _date.ticks_per_second);
    }
    const zone = _date.systemZone(ub);
    return _date.utcOfLocal(&zone, _date.localSeconds(date));
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

test "DateToUtc: a stamp of a system in UTC, and its fraction of a second" {
    const ub = try library.setUp();
    defer kexec.deinit();
    // 16 September 2026, 13:45:07 and 10 ticks: a fifth of a second.
    const stamp: DateStamp = .{ .days = 17_790, .minute = 13 * 60 + 45, .tick = 7 * 50 + 10 };
    var fraction: u32 = 0;
    const seconds = DateToUtc(ub, &stamp, &fraction);
    try testing.expectEqual(@as(i64, 1_789_566_307), seconds);
    try testing.expectEqual(@as(u32, 200_000_000), fraction);
    // The first moment a stamp holds.
    try testing.expectEqual(@as(i64, 252_460_800), DateToUtc(ub, &.{}, null));
}
