// SPDX-License-Identifier: MPL-2.0
//! GetProgramDir: the lock on the directory the running program was
//! loaded from.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const process = @import("_process.zig");
const FileLock = dos.FileLock;

/// Returns the running process's program directory (pr_HomeDir), the
/// directory PROGDIR: names.
///
/// SYNOPSIS:
/// ```zig
/// fn GetProgramDir(db: *DosBase) ?*FileLock
/// ```
///
/// SINCE: 1.0. LVO -280.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The lock on the directory the program came from, or null when it has
/// none (a program from ROM, or a plain Task). Without one, PROGDIR: is
/// looked up as an ordinary name.
///
/// BEHAVIOR:
/// Reads pr_HomeDir of the running process. Nothing is checked or
/// changed.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not safe; it reads the running task's Process.
/// - Forbid: not needed, and not taken.
/// - Process: a Process for an answer; from a plain Task it does
///   nothing and answers null.
///
/// OWNERSHIP:
/// The lock stays the process's; the caller must not UnLock it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetProgramDir`, `GetDeviceProc`
///
/// EXAMPLES:
/// ```zig
/// const dir = dos_lib.GetProgramDir() orelse return error.NoProgramDir;
/// ```
pub fn GetProgramDir(db: *DosBase) ?*FileLock {
    const proc = process.currentProcess(db.sys_base) orelse return null;
    return proc.home_dir;
}
