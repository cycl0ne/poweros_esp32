// SPDX-License-Identifier: MPL-2.0
//! CurrentDir: sets the process's current directory.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const process = @import("../process/_process.zig");
const FileLock = dos.FileLock;

/// Makes a lock the calling process's current directory and returns the one
/// before.
///
/// SYNOPSIS:
/// ```zig
/// fn CurrentDir(db: *DosBase, lock: ?*FileLock) ?*FileLock
/// ```
///
/// SINCE: 1.0. LVO -164.
///
/// INPUTS:
/// - `lock` - the new current directory; null means the root of the
///   process's file system.
///
/// RESULT:
/// The previous current directory (possibly null). Null from a plain task,
/// which has none.
///
/// BEHAVIOR:
/// pr_CurrentDir is swapped; no packet is sent. The lock is neither
/// checked, copied nor unlocked.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: allowed.
/// - Process: needed; a plain task changes nothing and gets null.
///
/// OWNERSHIP:
/// The process holds `lock` from now on without owning it: the caller still
/// gives it back, once it is no longer the current directory. The returned
/// lock goes back to the caller, the same way.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Lock`, `UnLock`, `GetCurrentDirName`
///
/// EXAMPLES:
/// ```zig
/// const old = dos_lib.CurrentDir(dir);
/// defer _ = dos_lib.CurrentDir(old);
/// ```
pub fn CurrentDir(db: *DosBase, lock: ?*FileLock) ?*FileLock {
    const proc = process.currentProcess(db.sys_base) orelse return null;
    const old = proc.current_dir;
    proc.current_dir = lock;
    return old;
}
