// SPDX-License-Identifier: MPL-2.0
//! FindCliProc: the process with a given CLI number.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const Process = dos.Process;

/// Returns the CLI process with a given number.
///
/// SYNOPSIS:
/// ```zig
/// fn FindCliProc(db: *DosBase, num: u32) ?*Process
/// ```
///
/// SINCE: 1.0. LVO -528.
///
/// INPUTS:
/// - `num` - the CLI number, pr_TaskNum; 1 is the first.
///
/// RESULT:
/// The process, or null if the number is free or out of range.
///
/// BEHAVIOR:
/// The CLI table is read under its lock.
///
/// CONTEXT:
/// - Waits: yes, for the CLI table's semaphore.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The process is not the caller's. It can end at any time after the call;
/// a caller that looks into it holds Forbid meanwhile.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MaxCli`
///
/// EXAMPLES:
/// ```zig
/// if (dos_lib.FindCliProc(1)) |shell| _ = shell;
/// ```
pub fn FindCliProc(db: *DosBase, num: u32) ?*Process {
    if (num == 0 or num > db.clis.len) return null;
    db.sys_base.ObtainSemaphoreShared(&db.cli_lock);
    defer db.sys_base.ReleaseSemaphore(&db.cli_lock);
    return db.clis[num - 1];
}
