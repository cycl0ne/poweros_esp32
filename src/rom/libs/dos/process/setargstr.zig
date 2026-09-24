// SPDX-License-Identifier: MPL-2.0
//! SetArgStr: sets the running command's argument line.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _process = @import("_process.zig");
const currentProcess = _process.currentProcess;

/// Sets the argument line of the calling process, and returns the one
/// before.
///
/// SYNOPSIS:
/// ```zig
/// fn SetArgStr(db: *DosBase, string: ?[*:0]const u8) ?[*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -520.
///
/// INPUTS:
/// - `string` - the new line, or null.
///
/// RESULT:
/// The previous pr_Arguments; null from a plain task, which changes
/// nothing.
///
/// BEHAVIOR:
/// pr_Arguments is set to `string`. A copy CreateNewProc made of
/// NP_Arguments stays the process's and is freed when it ends, whichever
/// line is set then; `string` is never freed by dos.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: allowed.
/// - Process: a process; a plain task changes nothing.
///
/// OWNERSHIP:
/// `string` stays the caller's, and must outlive its use as the argument
/// line. The returned line goes back to the caller.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetArgStr`, `RunCommand`
///
/// EXAMPLES:
/// ```zig
/// const old = dos_lib.SetArgStr("-v\n");
/// defer _ = dos_lib.SetArgStr(old);
/// ```
pub fn SetArgStr(db: *DosBase, string: ?[*:0]const u8) ?[*:0]const u8 {
    const sys = db.sys_base;
    const proc = currentProcess(sys) orelse return null;
    const old = proc.arguments;
    proc.arguments = string;
    return old;
}
