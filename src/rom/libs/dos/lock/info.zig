// SPDX-License-Identifier: MPL-2.0
//! Info: what the volume a lock is on holds and has left.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const asArg = _lock.asArg;
const lockAction = _lock.lockAction;
const FileLock = dos.FileLock;

/// Fills in an InfoData about the volume a lock is on.
///
/// SYNOPSIS:
/// ```zig
/// fn Info(db: *DosBase, lock: ?*FileLock, data: *dos.InfoData) bool
/// ```
///
/// SINCE: 1.0. LVO -392.
///
/// INPUTS:
/// - `lock` - a lock on anything on the volume; null asks the current
///   process's file system.
/// - `data` - the InfoData to fill in.
///
/// RESULT:
/// True if `data` is filled in; false with IoErr()
/// (ERROR_DEVICE_NOT_MOUNTED for null from a plain task, the handler's
/// error).
///
/// BEHAVIOR:
/// The lock's handler (for null, pr_FileSystemTask) is sent ACTION_INFO
/// with the lock and `data`.
///
/// CONTEXT:
/// - Waits: yes, for the handler's answer to a packet.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do; a process gets IoErr().
///
/// OWNERSHIP:
/// `data` is the caller's; the handler only writes it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Lock`, `IsFileSystem`
///
/// EXAMPLES:
/// ```zig
/// var info: dos.InfoData = .{};
/// if (dos_lib.Info(lock, &info)) used = info.num_blocks_used;
/// ```
pub fn Info(db: *DosBase, lock: ?*FileLock, data: *dos.InfoData) bool {
    return lockAction(db, lock, .info, asArg(lock), asArg(data)) != 0;
}
