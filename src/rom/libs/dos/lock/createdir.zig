// SPDX-License-Identifier: MPL-2.0
//! CreateDir: makes a directory and locks it.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const nameAction = _lock.nameAction;
const asLock = _lock.asLock;
const FileLock = dos.FileLock;

/// Makes a directory and returns an exclusive lock on it.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateDir(db: *DosBase, name: [*:0]const u8) ?*FileLock
/// ```
///
/// SINCE: 1.0. LVO -168.
///
/// INPUTS:
/// - `name` - the new directory's name, as for Lock.
///
/// RESULT:
/// An exclusive lock on the new directory, or null with IoErr()
/// (ERROR_OBJECT_EXISTS, ERROR_DISK_FULL, ERROR_LINE_TOO_LONG, the
/// handler's error).
///
/// BEHAVIOR:
/// The name's handler is sent ACTION_CREATE_DIR with the directory the name
/// is relative to and the whole name. On a multi-directory assign, the next
/// directory is tried while the answer is ERROR_OBJECT_NOT_FOUND.
///
/// CONTEXT:
/// - Waits: yes, for the handler's answer to a packet.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do; a process gets IoErr().
///
/// OWNERSHIP:
/// The lock is the caller's, to UnLock; the directory stays.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Lock`, `DeleteFile`
///
/// EXAMPLES:
/// ```zig
/// dos_lib.UnLock(dos_lib.CreateDir("RAM:T") orelse return false);
/// ```
pub fn CreateDir(db: *DosBase, name: [*:0]const u8) ?*FileLock {
    return asLock(nameAction(db, name, .create_dir, .{}));
}
