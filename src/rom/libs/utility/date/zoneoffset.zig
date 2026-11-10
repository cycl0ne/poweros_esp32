// SPDX-License-Identifier: MPL-2.0
//! ZoneOffset: how far the system's zone is from UTC at a moment.

const std = @import("std");

const UtilityBase = @import("../utility.zig").UtilityBase;
const _date = @import("_date.zig");

/// The seconds the zone the system clock keeps is east of UTC at a moment.
///
/// SYNOPSIS:
/// ```zig
/// fn ZoneOffset(ub: *UtilityBase, utc: i64) i32
/// ```
///
/// SINCE: 1.3. LVO -264.
///
/// INPUTS:
/// - `utc` - the moment, in seconds since 1 January 1970, UTC.
///
/// RESULT:
/// The seconds to add to `utc` for the local time then: 3600 for Central
/// European Time, 7200 for its summer time, -18000 for US Eastern; 0 in
/// UTC.
///
/// BEHAVIOR:
/// The zone is the rule battmem.resource holds (BATTMEM_ZONE), which the
/// boot's `C:SetClock ZONE` writes from ENV:Sys/timezone and Prefs writes
/// again when the zone is changed there. It is read for each call, so a
/// zone changed while a program runs is the one its next call uses. A
/// rule with summer time gives the summer offset between the changes the
/// rule names, in the year of the moment.
///
/// While nobody wrote the zone, and on a system without the resource, the
/// clock keeps UTC and the answer is 0.
///
/// CONTEXT:
/// - Waits: yes, for battmem.resource's semaphore while another task
///   holds it.
/// - Interrupts: no.
/// - Locks: none needed; battmem.resource takes its own for the read.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated or changes hands.
///
/// NOTES:
/// It sends no packet and reads no file, so a file system handler may ask
/// it about a volume that holds the zone file itself.
///
/// The offset is that of the moment, not of now: a date in July answers
/// with summer time in December. A file's date written with the offset it
/// had (`+0200`) takes the moment the file was written.
///
/// BUGS:
/// A rule whose offsets or changes are not whole quarter hours is not
/// kept by battmem.resource (`C:SetClock ZONE` says so), and the clock
/// then keeps UTC. Every zone in use today is whole quarter hours.
///
/// SEE ALSO:
/// `DateToUtc`, `UtcToDate`, sdk.dos.timezone
///
/// EXAMPLES:
/// ```zig
/// // A commit's date as git writes it: `1762686000 +0100`.
/// const offset = ub.ZoneOffset(seconds);
/// const minutes = @divTrunc(if (offset < 0) -offset else offset, 60);
/// _ = dos.stdio.Printf(dl, "%ld %c%02d%02d\n", .{ seconds, @as(u8, if (offset < 0) '-' else '+'), @divTrunc(minutes, 60), @mod(minutes, 60) });
/// ```
pub fn ZoneOffset(ub: *UtilityBase, utc: i64) i32 {
    const zone = _date.systemZone(ub);
    return zone.offsetAt(utc);
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

test "ZoneOffset: UTC on a system whose zone nobody set" {
    const ub = try library.setUp();
    defer kexec.deinit();
    try testing.expectEqual(@as(i32, 0), ZoneOffset(ub, 1_762_686_000));
    try testing.expectEqual(@as(i32, 0), ZoneOffset(ub, 0));
}
