// SPDX-License-Identifier: MPL-2.0
//! SetProgramDir: sets the lock on the running program's directory.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const process = @import("_process.zig");
const FileLock = dos.FileLock;

/// Sets the running process's program directory (pr_HomeDir) and
/// returns the one it replaces.
///
/// SYNOPSIS:
/// ```zig
/// fn SetProgramDir(db: *DosBase, lock: ?*FileLock) ?*FileLock
/// ```
///
/// SINCE: 1.0. LVO -284.
///
/// INPUTS:
/// - `lock` - the directory PROGDIR: names from now on; null for none.
///
/// RESULT:
/// The program directory (pr_HomeDir) that was set before, or null if
/// there was none - or if the caller is a plain Task, which has none to
/// set.
///
/// BEHAVIOR:
/// Writes `lock` into pr_HomeDir of the running process as it is:
/// nothing is checked, and the old value is only handed back, never
/// closed or freed.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not safe; it reads and changes the running task's
///   Process.
/// - Forbid: not needed, and not taken; only the running process
///   touches these fields.
/// - Process: a Process for an answer; from a plain Task it does
///   nothing and answers null.
///
/// OWNERSHIP:
/// The process takes `lock` over only in the sense that PROGDIR: uses
/// it; whoever set it unlocks it after setting the old one back. The
/// returned lock is the caller's to UnLock (or to restore).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetProgramDir`, `UnLock`
///
/// EXAMPLES:
/// ```zig
/// const old = dos_lib.SetProgramDir(dir);
/// defer dos_lib.UnLock(dos_lib.SetProgramDir(old));
/// ```
pub fn SetProgramDir(db: *DosBase, lock: ?*FileLock) ?*FileLock {
    const proc = process.currentProcess(db.sys_base) orelse return null;
    const old = proc.home_dir;
    proc.home_dir = lock;
    return old;
}
