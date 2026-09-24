// SPDX-License-Identifier: MPL-2.0
//! SetIoErr: sets what IoErr returns.

const DosBase = @import("../dos_base.zig").DosBase;
const _process = @import("_process.zig");
const currentProcess = _process.currentProcess;

/// Sets the calling process's secondary result, what IoErr() returns.
///
/// SYNOPSIS:
/// ```zig
/// fn SetIoErr(db: *DosBase, code: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// - `code` - the new value, usually an ERROR_* code or 0.
///
/// RESULT:
/// The value before; 0 from a plain task.
///
/// BEHAVIOR:
/// pr_Result2 is set. From a plain task nothing is set.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: allowed.
/// - Process: a process; a plain task changes nothing.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `IoErr`
///
/// EXAMPLES:
/// ```zig
/// if (argument == null) {
///     _ = dos_lib.SetIoErr(dos.ERROR_REQUIRED_ARG_MISSING);
///     return false;
/// }
/// ```
pub fn SetIoErr(db: *DosBase, code: i32) i32 {
    const sys = db.sys_base;
    const proc = currentProcess(sys) orelse return 0;
    const old = proc.result2;
    proc.result2 = code;
    return old;
}
