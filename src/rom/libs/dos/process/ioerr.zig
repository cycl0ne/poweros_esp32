// SPDX-License-Identifier: MPL-2.0
//! IoErr: the error the last dos call left for the calling process.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _process = @import("_process.zig");
const currentProcess = _process.currentProcess;

/// Returns the secondary result of the calling process's last dos call.
///
/// SYNOPSIS:
/// ```zig
/// fn IoErr(db: *DosBase) i32
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// pr_Result2: the error code (ERROR_*) a failed call left, or what a call
/// that answers with a count or a length left there. ERROR_NO_PROCESS from
/// a plain task.
///
/// BEHAVIOR:
/// pr_Result2 is read; it is not cleared. Every dos call that fails sets
/// it, and many that succeed set it too (a packet's dp_Res2 always lands
/// there), so it is read right after the call it belongs to.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: allowed.
/// - Process: a process; a plain task gets ERROR_NO_PROCESS.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetIoErr`, `Fault`, `PrintFault`
///
/// EXAMPLES:
/// ```zig
/// const lock = dos_lib.Lock(name, dos.SHARED_LOCK) orelse {
///     _ = dos_lib.PrintFault(dos_lib.IoErr(), name);
///     return;
/// };
/// ```
pub fn IoErr(db: *DosBase) i32 {
    const sys = db.sys_base;
    const proc = currentProcess(sys) orelse return dos.ERROR_NO_PROCESS;
    return proc.result2;
}
