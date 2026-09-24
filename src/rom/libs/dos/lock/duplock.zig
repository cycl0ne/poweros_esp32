// SPDX-License-Identifier: MPL-2.0
//! DupLock: a second shared lock on the object a lock is on.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const asArg = _lock.asArg;
const lockAction = _lock.lockAction;
const asLock = _lock.asLock;
const FileLock = dos.FileLock;

/// Makes another shared lock on the object a lock is on.
///
/// SYNOPSIS:
/// ```zig
/// fn DupLock(db: *DosBase, lock: ?*FileLock) ?*FileLock
/// ```
///
/// SINCE: 1.0. LVO -152.
///
/// INPUTS:
/// - `lock` - the lock to copy; null gives null.
///
/// RESULT:
/// The new lock, or null with IoErr() (ERROR_OBJECT_IN_USE for an exclusive
/// lock, or the handler's error). DupLock(null) is null without a packet,
/// and IoErr() is then not set.
///
/// BEHAVIOR:
/// The lock's handler is sent ACTION_COPY_DIR with the lock.
///
/// CONTEXT:
/// - Waits: yes, for the handler's answer to a packet.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do; a process gets IoErr().
///
/// OWNERSHIP:
/// The new lock is the caller's, given back with UnLock; the original stays
/// the caller's too.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Lock`, `UnLock`, `DupLockFromFH`
///
/// EXAMPLES:
/// ```zig
/// const copy = dos_lib.DupLock(proc.current_dir) orelse return false;
/// ```
pub fn DupLock(db: *DosBase, lock: ?*FileLock) ?*FileLock {
    const it = lock orelse return null; // no packet for nothing
    return asLock(lockAction(db, it, .copy_dir, asArg(it), 0));
}
