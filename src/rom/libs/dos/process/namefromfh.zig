// SPDX-License-Identifier: MPL-2.0
//! NameFromFH: the full name of the file an open handle is on.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _process = @import("_process.zig");
const FileInfoBlock = dos.FileInfoBlock;
const fail = _process.fail;
const FileHandle = dos.FileHandle;

/// Writes the full name of the file an open handle is on into the
/// caller's buffer.
///
/// SYNOPSIS:
/// ```zig
/// fn NameFromFH(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, size: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -380.
///
/// INPUTS:
/// - `file` - the open file.
/// - `buffer` - where the name goes, NUL-terminated.
/// - `size` - how many bytes `buffer` has, the NUL included.
///
/// RESULT:
/// True with the name in `buffer` ("Ram Disk:d/file"). False with IoErr
/// and an empty buffer: ERROR_LINE_TOO_LONG when it doesn't fit or
/// `size` is 0, or whatever ParentOfFH, ExamineFH, NameFromLock or
/// AllocDosObject said.
///
/// BEHAVIOR:
/// The file's directory comes from ParentOfFH and is named with
/// NameFromLock; the file's own name, from ExamineFH, is added with
/// AddPart. The parent lock and the FileInfoBlock used on the way are
/// freed before it returns.
///
/// CONTEXT:
/// - Waits: yes, for the handler's answers.
/// - Interrupts: not safe.
/// - Forbid: not to be held; it waits.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The handle stays the caller's and stays open. The buffer is the
/// caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NameFromLock`, `ParentOfFH`, `ExamineFH`
///
/// EXAMPLES:
/// ```zig
/// var name: [256]u8 = undefined;
/// if (dos_lib.NameFromFH(fh, &name, name.len)) _ = dos_lib.PutStr(@ptrCast(&name));
/// ```
pub fn NameFromFH(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, size: u32) bool {
    const dos_lib = db.iface();
    if (size == 0) return fail(db, dos.ERROR_LINE_TOO_LONG);
    buffer[0] = 0;
    const parent = dos_lib.ParentOfFH(file) orelse return false;
    defer dos_lib.UnLock(parent);
    const fib: *FileInfoBlock = @ptrCast(@alignCast(dos_lib.AllocDosObject(dos.DOS_FIB, null) orelse return false));
    defer dos_lib.FreeDosObject(dos.DOS_FIB, fib);
    if (!dos_lib.ExamineFH(file, fib)) return false;
    if (!dos_lib.NameFromLock(parent, buffer, size)) return false;
    if (!dos_lib.AddPart(@ptrCast(buffer), @ptrCast(&fib.file_name), size)) {
        buffer[0] = 0;
        return false;
    }
    return true;
}
