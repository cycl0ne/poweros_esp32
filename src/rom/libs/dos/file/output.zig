// SPDX-License-Identifier: MPL-2.0
//! Output: the running process's standard output.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const process = @import("../process/_process.zig");
const FileHandle = dos.FileHandle;

/// Gives the running process's output handle.
///
/// SYNOPSIS:
/// ```zig
/// fn Output(db: *DosBase) ?*FileHandle
/// ```
///
/// SINCE: 1.0. LVO -216.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// `pr_COS`, the process's output; null when there is none or the caller is
/// a plain Task.
///
/// BEHAVIOR:
/// Reads the field; nothing is opened.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It reads the running task.
/// - Forbid: not needed, and not taken.
/// - Process: a Process; from a plain Task the answer is null and nothing
///   changes.
///
/// OWNERSHIP:
/// The handle is the process's. Don't close it: whoever set it closes it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Input`, `SelectOutput`, `PutStr`
///
/// EXAMPLES:
/// ```zig
/// _ = dos_lib.FPuts(dos_lib.Output(), "done\n");
/// ```
pub fn Output(db: *DosBase) ?*FileHandle {
    const proc = process.currentProcess(db.sys_base) orelse return null;
    return proc.cos;
}
