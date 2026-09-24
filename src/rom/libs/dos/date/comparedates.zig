// SPDX-License-Identifier: MPL-2.0
//! CompareDates: which of two DateStamps is earlier.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;

/// Compares two DateStamps.
///
/// SYNOPSIS:
/// ```zig
/// fn CompareDates(_: *DosBase, date1: *const dos.DateStamp, date2: *const dos.DateStamp) i32
/// ```
///
/// SINCE: 1.0. LVO -180.
///
/// INPUTS:
/// - `date1` - the first date.
/// - `date2` - the second date.
///
/// RESULT:
/// Negative when `date1` is earlier, 0 when they are the same, positive
/// when `date2` is earlier. The result is -1, 0 or 1.
///
/// BEHAVIOR:
/// Days, then minutes, then ticks.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It only reads its inputs.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DateStamp`
///
/// EXAMPLES:
/// ```zig
/// if (dos_lib.CompareDates(&fib.date, &since) < 0) continue; // older
/// ```
pub fn CompareDates(_: *DosBase, date1: *const dos.DateStamp, date2: *const dos.DateStamp) i32 {
    if (date1.days != date2.days) return if (date1.days < date2.days) -1 else 1;
    if (date1.minute != date2.minute) return if (date1.minute < date2.minute) -1 else 1;
    if (date1.tick != date2.tick) return if (date1.tick < date2.tick) -1 else 1;
    return 0;
}
