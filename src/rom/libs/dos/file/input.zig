// SPDX-License-Identifier: MPL-2.0
//! Input: the running process's standard input.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const process = @import("../process/_process.zig");
const FileHandle = dos.FileHandle;

/// Gives the running process's input handle.
///
/// SYNOPSIS:
/// ```zig
/// fn Input(db: *DosBase) ?*FileHandle
/// ```
///
/// SINCE: 1.0. LVO -212.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// `pr_CIS`, the process's input; null when there is none or the caller is
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
/// `Output`, `SelectInput`, `FGetC`
///
/// EXAMPLES:
/// ```zig
/// const in = dos_lib.Input() orelse return;
/// const c = dos_lib.FGetC(in);
/// ```
pub fn Input(db: *DosBase) ?*FileHandle {
    const proc = process.currentProcess(db.sys_base) orelse return null;
    return proc.cis;
}
