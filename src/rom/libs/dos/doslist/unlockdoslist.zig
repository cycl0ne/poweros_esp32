// SPDX-License-Identifier: MPL-2.0
//! UnLockDosList: unlocks what LockDosList locked.

const DosBase = @import("../dos_base.zig").DosBase;
const _doslist = @import("_doslist.zig");
const semaphores = _doslist.semaphores;

/// Unlocks what LockDosList or AttemptLockDosList locked.
///
/// SYNOPSIS:
/// ```zig
/// fn UnLockDosList(db: *DosBase, flags: u32) void
/// ```
///
/// SINCE: 1.0. LVO -64.
///
/// INPUTS:
/// - `flags` - the flags the list was locked with.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Each semaphore the flags select is released once. The LDF_READ/LDF_WRITE
/// bits are not looked at.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: allowed.
/// - Process: a Task will do; the task that locked the list.
///
/// OWNERSHIP:
/// The locks go; nothing else changes hands.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockDosList`, `AttemptLockDosList`
///
/// EXAMPLES:
/// ```zig
/// dos_lib.UnLockDosList(dos.LDF_ALL | dos.LDF_READ);
/// ```
pub fn UnLockDosList(db: *DosBase, flags: u32) void {
    for (semaphores(db)) |s| {
        if (flags & s.bits != 0) db.sys_base.ReleaseSemaphore(s.sem);
    }
}
