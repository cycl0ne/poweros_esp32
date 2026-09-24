// SPDX-License-Identifier: MPL-2.0
//! GetArgStr: the running command's argument line.

const DosBase = @import("../dos_base.zig").DosBase;
const _process = @import("_process.zig");
const currentProcess = _process.currentProcess;

/// Returns the argument line of the command the calling process runs.
///
/// SYNOPSIS:
/// ```zig
/// fn GetArgStr(db: *DosBase) ?[*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -516.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// pr_Arguments, or null when there is none and from a plain task.
///
/// BEHAVIOR:
/// pr_Arguments is read.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: allowed.
/// - Process: a process; a plain task gets null.
///
/// OWNERSHIP:
/// The string stays the process's; it is valid while the command runs.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetArgStr`, `ReadArgs`
///
/// EXAMPLES:
/// ```zig
/// const line = dos_lib.GetArgStr() orelse "";
/// ```
pub fn GetArgStr(db: *DosBase) ?[*:0]const u8 {
    const sys = db.sys_base;
    const proc = currentProcess(sys) orelse return null;
    return proc.arguments;
}
