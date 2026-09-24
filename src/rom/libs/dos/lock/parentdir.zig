// SPDX-License-Identifier: MPL-2.0
//! ParentDir: a lock on the directory an object is in.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const asArg = _lock.asArg;
const lockAction = _lock.lockAction;
const asLock = _lock.asLock;
const FileLock = dos.FileLock;

/// Locks the directory an object is in.
///
/// SYNOPSIS:
/// ```zig
/// fn ParentDir(db: *DosBase, lock: ?*FileLock) ?*FileLock
/// ```
///
/// SINCE: 1.0. LVO -156.
///
/// INPUTS:
/// - `lock` - a lock on the object; null asks the current process's file
///   system about its root.
///
/// RESULT:
/// A shared lock on the parent directory, or null: at the root with IoErr()
/// 0, else with the error.
///
/// BEHAVIOR:
/// The lock's handler (for null, pr_FileSystemTask) is sent ACTION_PARENT
/// with the lock.
///
/// CONTEXT:
/// - Waits: yes, for the handler's answer to a packet.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do; a process gets IoErr().
///   With a null lock, a plain task has no file system and gets
/// ERROR_DEVICE_NOT_MOUNTED.
///
/// OWNERSHIP:
/// The new lock is the caller's; `lock` stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Lock`, `ParentOfFH`, `NameFromLock`
///
/// EXAMPLES:
/// ```zig
/// const up = dos_lib.ParentDir(here) orelse {
///     if (dos_lib.IoErr() == 0) return; // `here` is the root
///     return error.NoParent;
/// };
/// ```
pub fn ParentDir(db: *DosBase, lock: ?*FileLock) ?*FileLock {
    return asLock(lockAction(db, lock, .parent, asArg(lock), 0));
}
