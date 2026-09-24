// SPDX-License-Identifier: MPL-2.0
//! DateStamp: the time now.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _date = @import("_date.zig");
const fromSysTime = _date.fromSysTime;
const timer = sdk.devices.timer;

/// Reads the time now into a DateStamp.
///
/// SYNOPSIS:
/// ```zig
/// fn DateStamp(db: *DosBase, date: *dos.DateStamp) *dos.DateStamp
/// ```
///
/// SINCE: 1.0. LVO -176.
///
/// INPUTS:
/// - `date` - where the time goes.
///
/// RESULT:
/// `date`, filled in: days since 1 Jan 1978, minutes past midnight, ticks
/// of 1/50 s past the minute.
///
/// BEHAVIOR:
/// The time is timer.device's GetSysTime, on the request dos keeps open,
/// so the call neither waits nor allocates. Without timer.device every
/// field is 0.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. `date` is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CompareDates`, `DateToStr`, `Delay`
///
/// EXAMPLES:
/// ```zig
/// var now: dos.DateStamp = .{};
/// _ = dos_lib.DateStamp(&now);
/// ```
pub fn DateStamp(db: *DosBase, date: *dos.DateStamp) *dos.DateStamp {
    const tb = db.timer_base orelse {
        date.* = .{};
        return date;
    };
    var now: timer.TimeVal = .{};
    tb.GetSysTime(&now);
    date.* = fromSysTime(now.secs, now.micro);
    return date;
}
