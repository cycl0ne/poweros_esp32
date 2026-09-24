// SPDX-License-Identifier: MPL-2.0
//! DupLockFromFH: a lock on the file an open handle is on.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _file = @import("_file.zig");
const handleLock = _file.handleLock;
const FileLock = dos.FileLock;
const FileHandle = dos.FileHandle;

/// Gives a shared lock on an open file.
///
/// SYNOPSIS:
/// ```zig
/// fn DupLockFromFH(db: *DosBase, file: ?*FileHandle) ?*FileLock
/// ```
///
/// SINCE: 1.0. LVO -372.
///
/// INPUTS:
/// - `file` - the handle.
///
/// RESULT:
/// A shared lock on the file, or null with `IoErr()` set
/// (`ERROR_INVALID_LOCK` for a null handle or one without a handler,
/// `ERROR_NO_FREE_STORE`, or the handler's code).
///
/// BEHAVIOR:
/// `ACTION_COPY_DIR_FH` with the handle to its handler, which makes the
/// lock.
///
/// CONTEXT:
/// - Waits: yes: it sends the handler a packet and waits for the answer.
/// - Interrupts: no. It waits.
/// - Forbid: not taken, and never to be held around it: it waits.
/// - Process: a Task will do; the answer comes back on a port of its own.
///
/// OWNERSHIP:
/// The lock is the caller's, for `UnLock`. The handle stays open.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ParentOfFH`, `OpenFromLock`, `UnLock`
///
/// EXAMPLES:
/// ```zig
/// const l = dos_lib.DupLockFromFH(fh) orelse return dos_lib.IoErr();
/// defer dos_lib.UnLock(l);
/// ```
pub fn DupLockFromFH(db: *DosBase, file: ?*FileHandle) ?*FileLock {
    return handleLock(db, file, .copy_dir_fh);
}
