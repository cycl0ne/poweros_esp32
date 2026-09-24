// SPDX-License-Identifier: MPL-2.0
//! OpenFromLock: turns a lock on a file into an open handle on it.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const packets = @import("../packet/_packet.zig");
const locks = @import("../lock/_lock.zig");
const ActionCode = dos.ActionCode;
const FileHandle = dos.FileHandle;
const FileLock = dos.FileLock;

/// Opens the file a lock is on.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenFromLock(db: *DosBase, lock: ?*FileLock) ?*FileHandle
/// ```
///
/// SINCE: 1.0. LVO -384.
///
/// INPUTS:
/// - `lock` - a lock on a file (not a directory).
///
/// RESULT:
/// The handle, or null with `IoErr()` set: `ERROR_OBJECT_WRONG_TYPE` for a
/// null lock, `ERROR_INVALID_LOCK` for one without a handler,
/// `ERROR_NO_FREE_STORE`, or the handler's code.
///
/// BEHAVIOR:
/// `ACTION_FH_FROM_LOCK` goes to the lock's handler with a new handle and
/// the lock. On success the handler has taken the lock into the open file.
///
/// CONTEXT:
/// - Waits: yes: it sends the handler a packet and waits for the answer.
/// - Interrupts: no. It waits.
/// - Forbid: not taken, and never to be held around it: it waits.
/// - Process: a Task will do; the answer comes back on a port of its own.
///
/// OWNERSHIP:
/// On success the lock belongs to the file: it is not unlocked by the
/// caller, and `Close` ends both. On failure the lock stays the caller's,
/// to unlock. The handle is the caller's, for `Close`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Open`, `DupLockFromFH`, `Lock`
///
/// EXAMPLES:
/// ```zig
/// const l = dos_lib.Lock("RAM:notes", dos.SHARED_LOCK) orelse return dos_lib.IoErr();
/// const fh = dos_lib.OpenFromLock(l) orelse {
///     dos_lib.UnLock(l);
///     return dos_lib.IoErr();
/// };
/// defer _ = dos_lib.Close(fh);
/// ```
pub fn OpenFromLock(db: *DosBase, lock: ?*FileLock) ?*FileHandle {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    const l = lock orelse {
        _ = dos_lib.SetIoErr(dos.ERROR_OBJECT_WRONG_TYPE);
        return null;
    };
    const port = l.task orelse {
        _ = dos_lib.SetIoErr(dos.ERROR_INVALID_LOCK);
        return null;
    };
    const block = dos_lib.AllocDosObject(dos.DOS_FILEHANDLE, null) orelse return null;
    const fh: *FileHandle = @ptrCast(@alignCast(block));
    fh.task = port;
    const answer = packets.exchange(sys, port, @intFromEnum(ActionCode.fh_from_lock), .{ locks.asArg(fh), locks.asArg(l), 0, 0, 0 }) orelse {
        dos_lib.FreeDosObject(dos.DOS_FILEHANDLE, fh);
        _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return null;
    };
    if (answer.res1 == 0) {
        dos_lib.FreeDosObject(dos.DOS_FILEHANDLE, fh);
        _ = dos_lib.SetIoErr(answer.res2);
        return null;
    }
    return fh;
}
