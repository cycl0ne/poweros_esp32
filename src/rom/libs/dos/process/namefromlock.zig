// SPDX-License-Identifier: MPL-2.0
//! NameFromLock: the full name of the object a lock is on.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _process = @import("_process.zig");
const build = _process.build;
const Path = _process.Path;
const FileInfoBlock = dos.FileInfoBlock;
const fail = _process.fail;
const FileLock = dos.FileLock;

/// Writes the full name of the object a lock is on, volume first, into
/// the caller's buffer.
///
/// SYNOPSIS:
/// ```zig
/// fn NameFromLock(db: *DosBase, lock: ?*FileLock, buffer: [*]u8, size: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -312.
///
/// INPUTS:
/// - `lock` - the file or directory to name; null is the root of the
///   process's default file system.
/// - `buffer` - where the name goes, NUL-terminated.
/// - `size` - how many bytes `buffer` has, the NUL included.
///
/// RESULT:
/// True with the name in `buffer` ("Ram Disk:d/file", or "Ram Disk:"
/// for a root). False, with IoErr and an empty buffer:
/// ERROR_LINE_TOO_LONG when it doesn't fit or `size` is 0,
/// ERROR_NO_FREE_STORE, ERROR_INVALID_LOCK, ERROR_DEVICE_NOT_MOUNTED
/// for a null lock without a default file system, or what the handler
/// answered.
///
/// BEHAVIOR:
/// The lock is copied (ACTION_COPY_DIR) and the copy walked up to the
/// root with ACTION_PARENT, each level's name taken from
/// ACTION_EXAMINE_OBJECT and put in from the buffer's end; the caller's
/// own lock is never examined, so an ExNext running on it is not
/// disturbed. The volume's name comes from its volume node, or from
/// examining the root when the lock has none. The finished name is then
/// moved to the buffer's start. The packets are sent directly, so a
/// plain Task can call it too.
///
/// CONTEXT:
/// - Waits: yes, for the handler's answers.
/// - Interrupts: not safe.
/// - Forbid: not to be held; it waits.
/// - Process: a Task will do; a null lock needs a Process (its
///   pr_FileSystemTask).
///
/// OWNERSHIP:
/// The lock stays the caller's and is unchanged. Every lock made on the
/// way is freed. The buffer is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NameFromFH`, `ParentDir`, `Examine`, `GetCurrentDirName`
///
/// EXAMPLES:
/// ```zig
/// var name: [256]u8 = undefined;
/// if (!dos_lib.NameFromLock(lock, &name, name.len)) return dos_lib.IoErr();
/// ```
pub fn NameFromLock(db: *DosBase, lock: ?*FileLock, buffer: [*]u8, size: u32) bool {
    const dos_lib = db.iface();
    if (size == 0) return fail(db, dos.ERROR_LINE_TOO_LONG);
    buffer[0] = 0;
    const fib: *FileInfoBlock = @ptrCast(@alignCast(dos_lib.AllocDosObject(dos.DOS_FIB, null) orelse return false));
    defer dos_lib.FreeDosObject(dos.DOS_FIB, fib);
    var path: Path = .{ .out = buffer[0..size], .pos = size - 1 };
    buffer[size - 1] = 0;
    const code = build(db, lock, fib, &path);
    if (code != 0) {
        buffer[0] = 0;
        return fail(db, code);
    }
    db.sys_base.CopyMem(buffer + path.pos, buffer, size - path.pos);
    return true;
}
