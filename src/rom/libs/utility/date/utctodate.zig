// SPDX-License-Identifier: MPL-2.0
//! UtcToDate: a moment in UTC as a DateStamp of the system clock.

const std = @import("std");
const sdk = @import("sdk");

const UtilityBase = @import("../utility.zig").UtilityBase;
const DateStamp = sdk.dos.DateStamp;
const _date = @import("_date.zig");

/// Seconds since 1970 in UTC as a DateStamp in the zone the system clock
/// keeps.
///
/// SYNOPSIS:
/// ```zig
/// fn UtcToDate(ub: *UtilityBase, utc: i64, date: *dos.DateStamp) void
/// ```
///
/// SINCE: 1.3. LVO -272.
///
/// INPUTS:
/// - `utc` - the moment, in seconds since 1 January 1970, UTC: what a
///   time server, a file server or a certificate gives.
/// - `date` - filled in with the stamp.
///
/// RESULT:
/// Nothing. `date` is always written.
///
/// BEHAVIOR:
/// The moment is moved into the system's zone by the offset it has then
/// (see `ZoneOffset`) and written as days since 1 January 1978, minutes
/// since midnight and ticks into the minute - whole seconds, the ticks a
/// multiple of 50. A moment whose local time is before 1978 is the
/// stamp's first moment, all fields 0; one past what its days hold is its
/// last.
///
/// While nobody wrote the zone, the stamp is UTC.
///
/// CONTEXT:
/// - Waits: yes, for battmem.resource's semaphore while another task
///   holds it.
/// - Interrupts: no.
/// - Locks: none needed; battmem.resource takes its own for the read.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. `date` is the caller's.
///
/// NOTES:
/// It sends no packet and reads no file, so a file system handler may ask
/// it for a date on the volume that holds the zone file.
///
/// A fraction of a second is the caller's to add to `tick` (a tick is a
/// fiftieth): the count of seconds holds none.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DateToUtc`, `ZoneOffset`, `DateSplit`
///
/// EXAMPLES:
/// ```zig
/// // A file's date as an SFTP server sends it, made the volume's.
/// var date: dos.DateStamp = .{};
/// ub.UtcToDate(attributes.mtime, &date);
/// _ = dl.SetFileDate(name, &date);
/// ```
pub fn UtcToDate(ub: *UtilityBase, utc: i64, date: *DateStamp) void {
    const zone = _date.systemZone(ub);
    date.* = _date.stampOfLocal(utc + zone.offsetAt(utc));
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");
const DateToUtc = @import("datetoutc.zig").DateToUtc;

test "UtcToDate: a moment of a system in UTC, and back" {
    const ub = try library.setUp();
    defer kexec.deinit();
    var date: DateStamp = .{};
    UtcToDate(ub, 1_789_566_307, &date);
    try testing.expect(date.eql(.{ .days = 17_790, .minute = 13 * 60 + 45, .tick = 7 * 50 }));
    try testing.expectEqual(@as(i64, 1_789_566_307), DateToUtc(ub, &date, null));
}

test "UtcToDate: before 1978 is the stamp's first moment" {
    const ub = try library.setUp();
    defer kexec.deinit();
    var date: DateStamp = .{ .days = 5, .minute = 5, .tick = 5 };
    UtcToDate(ub, 0, &date);
    try testing.expect(date.eql(.{}));
}
