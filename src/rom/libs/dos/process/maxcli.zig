// SPDX-License-Identifier: MPL-2.0
//! MaxCli: the highest CLI number in use.

const DosBase = @import("../dos_base.zig").DosBase;

/// Returns the highest CLI number in use.
///
/// SYNOPSIS:
/// ```zig
/// fn MaxCli(db: *DosBase) u32
/// ```
///
/// SINCE: 1.0. LVO -524.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The highest number a CLI process has, or 0 when there is none.
///
/// BEHAVIOR:
/// The CLI table is read under its lock. Numbers below the result may be
/// free.
///
/// CONTEXT:
/// - Waits: yes, for the CLI table's semaphore.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindCliProc`
///
/// EXAMPLES:
/// ```zig
/// var num: u32 = 1;
/// while (num <= dos_lib.MaxCli()) : (num += 1) {
///     if (dos_lib.FindCliProc(num)) |proc| show(num, proc);
/// }
/// ```
pub fn MaxCli(db: *DosBase) u32 {
    db.sys_base.ObtainSemaphoreShared(&db.cli_lock);
    defer db.sys_base.ReleaseSemaphore(&db.cli_lock);
    var max: u32 = 0;
    for (db.clis, 0..) |p, i| {
        if (p != null) max = @intCast(i + 1);
    }
    return max;
}
